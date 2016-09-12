local redis_connector = require("resty.redis.connector").new()
local math_floor = math.floor
local math_ceil = math.ceil
local ffi = require "ffi"
local ffi_cdef = ffi.cdef
local ffi_new = ffi.new
local ffi_string = ffi.string
local C = ffi.C

ffi_cdef[[
typedef unsigned char u_char;
u_char * ngx_hex_dump(u_char *dst, const u_char *src, size_t len);
int RAND_pseudo_bytes(u_char *buf, int num);
]]


local function random_hex(len)
    local len = math_floor(len / 2)

    local bytes = ffi_new("uint8_t[?]", len)
    C.RAND_pseudo_bytes(bytes, len)
    if not bytes then
        ngx_log(ngx_ERR, "error getting random bytes via FFI")
        return nil
    end

    local hex = ffi_new("uint8_t[?]", len * 2)
    C.ngx_hex_dump(hex, bytes, len)
    return ffi_string(hex, len * 2)
end


function scan(cursor, redis)
    local res, err = redis:scan(
        cursor,
        "MATCH", "ledge:cache:*::key", -- We use the "main" key to single out a cache entry
        "COUNT", 100
    )

    if not res or res == ngx_null then
        return nil, "SCAN error: " .. tostring(err)
    else
        for _,key in ipairs(res[2]) do
            -- Strip the "main" suffix to find the cache key
            local cache_key = string.sub(key, 1, -(string.len("::key") + 1))

            local entity, err = redis:get(cache_key .. "::key")
            if not entity or entity == ngx.null then
                ngx.say(err)
                return
            end

            local memused, err = redis:get(cache_key .. "::memused")

            -- Get the entity score
            local score, err = redis:zscore(
                cache_key .. "::entities",
                cache_key .. "::" .. entity
            )
            if not score or score == ngx.null then
                ngx.say("Unable to get entity score: ", err)
            end

            local entity_count, err = redis:zcard(cache_key .. "::entities")
            if not entity_count or entity_count == ngx.null then
                ngx.say("Could not count entity set: ", err)
            end

            -- Start transaction
            redis:multi()

            -- Move main entity to main key
            local ok, err = redis:rename(cache_key .. "::" .. entity, cache_key .. "::main")
            if not ok or ok == ngx.null then
                ngx.say("Renaming entity to main failed: ", err)
            end

            -- Rename headers etc
            for _, k in ipairs({ "headers", "reval_req_headers", "reval_params" }) do
                local ok, err = redis:rename(
                    cache_key .. "::" .. entity .. ":" .. k,
                    cache_key .. "::" .. k
                )
                if not ok or ok == ngx.null then
                    ngx.say("Renaming ", k, " failed: ", err)
                end
            end

            -- Create a new entity id and rename the live entity to it
            local new_entity_id = random_hex(32)
            for _, k in ipairs({ "body", "body_esi" }) do
                local ok, err = redis:rename(
                    cache_key .. "::" .. entity .. ":" .. k,
                    "ledge:entity:" .. new_entity_id .. ":" .. k
                )
                if not ok or ok == ngx.null then
                    ngx.say("Renaming ", k, " failed: ", err)
                end
            end

            -- Add the entity to the entities set
            local res, err = redis:zadd(cache_key .. "::entities", score, new_entity_id)
            if not res or res == ngx.null then
                ngx.say("Unable to add to entities set: ", err)
            end

            -- Remove the old form
            local res, err = redis:zrem(
                cache_key .. "::entities",
                cache_key .. "::" .. entity
            )
            if not res or res == ngx.null then
                ngx.say("Unable to remove old entity from entities set: ", err)
            end

            --  Add the live entity pointer to the main hash, and delete the old pointer
            local ok, err = redis:hset(cache_key .. "::main", "entity", new_entity_id)
            if not ok or ok == ngx.null then
                ngx.say("Setting entity id failed: ", err)
            else
                local ok, err = redis:del(cache_key .. "::key")
                if not ok or ok == ngx.null then
                    ngx.say("Could not delete key: ", err)
                end
            end

            -- Add the memused to the main hash, and delete the old key
            local ok, err = redis:hset(cache_key .. "::main", "memused", memused)
            if not ok or ok == ngx.null then
                ngx.say("Setting memused failed: ", err)
            else
                local ok, err = redis:del(cache_key .. "::memused")
                if not ok or ok == ngx.null then
                    ngx.say("Could not delete memused: ", err)
                end
            end

            -- Look for old entities (things about to be GC'd, but which will fail with the new codebase)
            -- and delete them.
            if entity_count > 1 then
                -- We have old things to clean up
                local members, err = redis:zrange(
                    cache_key .. "::entities",
                    0,
                    -1
                )
                if not members or members == ngx.null then
                    ngx.say("Could not get entity set members: ", err)
                end

                for _, member in pairs(members) do
                    if member ~= new_entity_id then
                        local keys = {
                            member,
                            member .. ":reval_req_headers",
                            member .. ":reval_params",
                            member .. ":headers",
                            member .. ":body",
                            member .. ":body_esi",
                        }

                        local res, err = redis:del(unpack(keys))
                        if not res or res == ngx.null or res < 6 then
                            ngx.say("Could not delete old entity: ", err)
                        end

                        -- Remove from the entities set
                        local res, err = redis:zrem(
                            cache_key .. "::entities",
                            member
                        )
                        if not res or res == ngx.null then
                            ngx.say("Could not remove old entity from the entities set: ", err)
                        end
                    end
                end
            end

            local res, err = redis:exec()
            if not res or res == ngx.null then
                ngx.say("Could not modify cache key ", cache_key, ": ", err)
                keys_failed = keys_failed + 1
            else
                keys_processed = keys_processed + 1
            end

            -- TODO:
            --  - What happens if cache is updated before the script runs?
            --  - Report errors
        end
    end

    local cursor = tonumber(res[1])
    if cursor > 0 then
        -- If we have a valid cursor, recurse to move on.
        return scan(cursor, redis)
    end

    return true
end


local redis, err = redis_connector:connect{ url = "redis://127.0.0.1:6379/0" }
if not redis then
    ngx.say(err)
    return
end

keys_processed = 0
keys_failed = 0

ngx.say("Migrating Ledge data structure from v1.26 to v1.27")

local res, err = scan(0, redis)
if res then
    ngx.say(keys_processed .. " cache entries successfully updated")
    ngx.say(keys_failed .. " failures")
end
