local CONFIG = {
    enabled = true,
    rules = {
        [403] = {
            count = 5,
            window = 60,
            ban = 1800
        },
        [401] = {
            count = 10,
            window = 60,
            ban = 3600
        },
        [404] = {
            count = 50,
            window = 60,
            ban = 900
        }
    },
    whitelist = {
        "127.0.0.1",
        "::1",
    }
}
local _M = {}
local bit = require "bit"
local whitelist_v4 = {}
local whitelist_v6 = {}

local function ipv4_to_u32(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil
    end
    a = tonumber(a)
    b = tonumber(b)
    c = tonumber(c)
    d = tonumber(d)
    if not a or not b or not c or not d
        or a > 255
        or b > 255
        or c > 255
        or d > 255 then
        return nil
    end
    return bit.bor(
        bit.lshift(a, 24),
        bit.lshift(b, 16),
        bit.lshift(c, 8),
        d
    )
end

local function ipv6_to_u32(ip)
    if not ip:find(":", 1, true) then
        return nil
    end
    local left, right = ip:match("^(.-)::(.-)$")
    local groups = {}
    if left then
        local l = {}
        local r = {}
        if left ~= "" then
            for part in left:gmatch("[^:]+") do
                l[#l + 1] = part
            end
        end
        if right ~= "" then
            for part in right:gmatch("[^:]+") do
                r[#r + 1] = part
            end
        end
        if #l + #r >= 8 then
            return nil
        end
        for i = 1, #l do
            groups[#groups + 1] = l[i]
        end
        for _ = 1, 8 - #l - #r do
            groups[#groups + 1] = "0"
        end
        for i = 1, #r do
            groups[#groups + 1] = r[i]
        end
    else
        for part in ip:gmatch("[^:]+") do
            groups[#groups + 1] = part
        end
        if #groups ~= 8 then
            return nil
        end
    end
    if #groups ~= 8 then
        return nil
    end
    local result = {}
    for i = 1, 8, 2 do
        local hi = tonumber(groups[i], 16)
        local lo = tonumber(groups[i + 1], 16)
        if not hi
            or not lo
            or hi > 0xffff
            or lo > 0xffff then
            return nil
        end
        result[#result + 1] = bit.bor(
            bit.lshift(hi, 16),
            lo
        )
    end
    return result
end

local function parse_cidr(entry)
    local ip, prefix = entry:match("^([^/]+)/(%d+)$")
    if not ip then
        ip = entry
    else
        prefix = tonumber(prefix)
    end
    local v4 = ipv4_to_u32(ip)
    if v4 then
        prefix = prefix or 32
        if prefix < 0 or prefix > 32 then
            return nil
        end
        local mask
        if prefix == 0 then
            mask = 0
        else
            mask = bit.lshift(0xffffffff, 32 - prefix)
        end
        return {
            family = 4,
            network = bit.band(v4, mask),
            mask = mask,
            prefix = prefix
        }
    end
    local v6 = ipv6_to_u32(ip)
    if v6 then
        prefix = prefix or 128
        if prefix < 0 or prefix > 128 then
            return nil
        end
        local network = {}
        local full = math.floor(prefix / 32)
        local remain = prefix % 32
        for i = 1, 4 do
            if i <= full then
                network[i] = v6[i]
            elseif i == full + 1 and remain > 0 then
                local mask = bit.lshift(0xffffffff, 32 - remain)
                network[i] = bit.band(v6[i], mask)
            else
                network[i] = 0
            end
        end
        return {
            family = 6,
            network = network,
            prefix = prefix
        }
    end
    return nil
end

local function ipv6_match(ip, rule)
    local value = ipv6_to_u32(ip)
    if not value then
        return false
    end
    local full = math.floor(rule.prefix / 32)
    local remain = rule.prefix % 32
    for i = 1, full do
        if value[i] ~= rule.network[i] then
            return false
        end
    end
    if remain > 0 then
        local mask = bit.lshift(0xffffffff, 32 - remain)
        if bit.band(value[full + 1], mask) ~= bit.band(rule.network[full + 1], mask) then
            return false
        end
    end
    return true
end

local function is_whitelisted(ip)
    local v4 = ipv4_to_u32(ip)
    if v4 then
        for _, rule in ipairs(whitelist_v4) do
            if bit.band(v4, rule.mask) == rule.network then
                return true
            end
        end
        return false
    end
    for _, rule in ipairs(whitelist_v6) do
        if ipv6_match(ip, rule) then
            return true
        end
    end
    return false
end

local function get_dict()
    return ngx.shared.security
end

local function ban_key(ip)
    return "ban:" .. ip
end

local function count_key(status, ip)
    return "count:" .. status .. ":" .. ip
end

local function is_banned(ip)
    local dict = get_dict()
    local expires = dict:get(ban_key(ip))
    if not expires then
        return false
    end
    if expires <= ngx.now() then
        dict:delete(ban_key(ip))
        return false
    end
    return true, expires
end

function _M.init()
    whitelist_v4 = {}
    whitelist_v6 = {}
    for _, entry in ipairs(CONFIG.whitelist or {}) do
        local rule = parse_cidr(entry)
        if rule then
            if rule.family == 4 then
                whitelist_v4[#whitelist_v4 + 1] = rule
            else
                whitelist_v6[#whitelist_v6 + 1] = rule
            end
        else
            ngx.log(ngx.ERR, "invalid whitelist entry: ", entry)
        end
    end
end

function _M.access()
    if not CONFIG.enabled then
        return
    end
    local ip = ngx.var.remote_addr
    if not ip or is_whitelisted(ip) then
        return
    end
    if is_banned(ip) then
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
end

function _M.log()
    if not CONFIG.enabled then
        return
    end
    local status = ngx.status
    local rule = CONFIG.rules[status]
    if not rule then
        return
    end
    local ip = ngx.var.remote_addr
    if not ip or is_whitelisted(ip) then
        return
    end
    if is_banned(ip) then
        return
    end
    local dict = get_dict()
    local key = count_key(status, ip)
    local count, err = dict:incr(key, 1, 0, rule.window)
    if not count then
        ngx.log(ngx.ERR, "security counter failed: ", err or "unknown error")
        return
    end
    if count >= rule.count then
        dict:set(ban_key(ip), ngx.now() + rule.ban, rule.ban)
        dict:delete(key)
        ngx.log(ngx.WARN, "security ban ip=", ip, " status=", status, " count=", count, " ban=", rule.ban, "s")
    end
end

function _M.ban(ip, duration)
    if not ip or ip == "" then
        return false
    end
    duration = tonumber(duration) or 1800
    if duration <= 0 then
        return false
    end
    if is_whitelisted(ip) then
        return false
    end
    local dict = get_dict()
    dict:set(ban_key(ip), ngx.now() + duration, duration)
    for status in pairs(CONFIG.rules) do
        dict:delete(count_key(status, ip))
    end
    ngx.log(ngx.WARN, "security manual ban ip=", ip, " ban=", duration, "s")
    return true
end

function _M.unban(ip)
    if not ip or ip == "" then
        return false
    end
    local dict = get_dict()
    dict:delete(ban_key(ip))
    for status in pairs(CONFIG.rules) do
        dict:delete(count_key(status, ip))
    end
    ngx.log(ngx.INFO, "security unban ip=", ip)
    return true
end

function _M.status()
    local dict = get_dict()
    local now = ngx.now()
    local banned = {}
    local counters = {}

    for _, key in ipairs(dict:get_keys(0)) do
        if key:sub(1, 4) == "ban:" then
            local ip = key:sub(5)
            local expires = dict:get(key)
            if expires and expires > now then
                banned[#banned + 1] = {
                    ip = ip,
                    expires = expires,
                    remaining = math.floor(expires - now)
                }
            end
        elseif key:sub(1, 6) == "count:" then
            local status, ip = key:match("^count:(%d+):(.+)$")
            if status and ip then
                local count = dict:get(key)
                if count then
                    counters[#counters + 1] = {
                        status = tonumber(status),
                        ip = ip,
                        count = count
                    }
                end
            end
        end
    end

    local rules_arr = {}
    for status_code, cfg in pairs(CONFIG.rules) do
        table.insert(rules_arr, {
            status = status_code,
            count  = cfg.count,
            window = cfg.window,
            ban    = cfg.ban
        })
    end

    return {
        enabled   = CONFIG.enabled,
        rules     = rules_arr,
        whitelist = CONFIG.whitelist,
        banned    = banned,
        counters  = counters
    }
end

function _M.status_json()
    ngx.header.content_type = "application/json; charset=utf-8"
    local cjson = require "cjson.safe"
    local data = _M.status()
    local json_str, err = cjson.encode(data)
    if not json_str then
        ngx.log(ngx.ERR, "status_json encode error: ", err)
        ngx.status = 500
        ngx.say(cjson.encode({ error = err }))
        return
    end
    ngx.say(json_str)
end

function _M.ban_json(ip)
    ngx.header.content_type = "application/json; charset=utf-8"
    local cjson = require "cjson.safe"
    local args = ngx.req.get_uri_args()
    local duration = tonumber(args.duration) or 1800
    if _M.ban(ip, duration) then
        ngx.say(cjson.encode({
            success = true,
            ip = ip,
            duration = duration
        }))
    else
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.say(cjson.encode({
            success = false,
            error = "invalid ip or whitelisted ip"
        }))
    end
end

function _M.unban_json(ip)
    ngx.header.content_type = "application/json; charset=utf-8"
    local cjson = require "cjson.safe"
    if _M.unban(ip) then
        ngx.say(cjson.encode({
            success = true,
            ip = ip
        }))
    else
        ngx.status = ngx.HTTP_BAD_REQUEST
        ngx.say(cjson.encode({
            success = false,
            error = "invalid ip"
        }))
    end
end

return _M
