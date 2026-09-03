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
        "::1"
    }
}


local _M = {}

local bit = require "bit"
local cjson = require "cjson.safe"

local ngx_now = ngx.now
local ngx_exit = ngx.exit
local ngx_log = ngx.log
local ngx_var = ngx.var
local ngx_ctx = ngx.ctx

local ERR = ngx.ERR
local WARN = ngx.WARN
local INFO = ngx.INFO

local HTTP_OK = ngx.HTTP_OK
local HTTP_FORBIDDEN = ngx.HTTP_FORBIDDEN
local HTTP_BAD_REQUEST = ngx.HTTP_BAD_REQUEST
local HTTP_INTERNAL_SERVER_ERROR =
    ngx.HTTP_INTERNAL_SERVER_ERROR

local whitelist_v4 = {}
local whitelist_v6 = {}


---------------------------------------------------------------------
-- IPv4
---------------------------------------------------------------------

local function ipv4_to_u32(ip)
    local a, b, c, d =
        ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

    if not a then
        return nil
    end

    a = tonumber(a)
    b = tonumber(b)
    c = tonumber(c)
    d = tonumber(d)

    if not a or a > 255
        or not b or b > 255
        or not c or c > 255
        or not d or d > 255 then
        return nil
    end

    return bit.bor(
        bit.lshift(a, 24),
        bit.lshift(b, 16),
        bit.lshift(c, 8),
        d
    )
end


---------------------------------------------------------------------
-- IPv6
--
-- Return four uint32 values.
-- No 8-element IPv6 temporary table is created.
---------------------------------------------------------------------

local function parse_ipv6_side(side)
    if side == "" then
        return 0, nil, nil, nil, nil
    end

    local count = 0
    local v1
    local v2
    local v3
    local v4

    for part in side:gmatch("[^:]+") do
        local value = tonumber(part, 16)

        if not value or value > 0xffff then
            return nil
        end

        count = count + 1

        if count == 1 then
            v1 = value
        elseif count == 2 then
            v2 = value
        elseif count == 3 then
            v3 = value
        elseif count == 4 then
            v4 = value
        else
            return nil
        end
    end

    return count, v1, v2, v3, v4
end


local function ipv6_to_u32(ip)
    if not ip:find(":", 1, true) then
        return nil
    end

    local left, right = ip:match("^(.-)::(.-)$")

    if left then
        local lc, l1, l2, l3, l4 =
            parse_ipv6_side(left)

        if not lc then
            return nil
        end

        local rc, r1, r2, r3, r4 =
            parse_ipv6_side(right)

        if not rc then
            return nil
        end

        if lc + rc >= 8 then
            return nil
        end

        local zero = 8 - lc - rc

        local g1, g2, g3, g4
        local g5, g6, g7, g8

        local values = {}

        if lc > 0 then
            values[1] = l1
            values[2] = l2
            values[3] = l3
            values[4] = l4
        end

        local pos = lc

        for _ = 1, zero do
            pos = pos + 1
            values[pos] = 0
        end

        if rc > 0 then
            values[pos + 1] = r1
            values[pos + 2] = r2
            values[pos + 3] = r3
            values[pos + 4] = r4
        end

        g1 = values[1] or 0
        g2 = values[2] or 0
        g3 = values[3] or 0
        g4 = values[4] or 0
        g5 = values[5] or 0
        g6 = values[6] or 0
        g7 = values[7] or 0
        g8 = values[8] or 0

        return
            bit.bor(bit.lshift(g1, 16), g2),
            bit.bor(bit.lshift(g3, 16), g4),
            bit.bor(bit.lshift(g5, 16), g6),
            bit.bor(bit.lshift(g7, 16), g8)
    end

    local count = 0
    local v1
    local v2
    local v3
    local v4
    local v5
    local v6
    local v7
    local v8

    for part in ip:gmatch("[^:]+") do
        local value = tonumber(part, 16)

        if not value or value > 0xffff then
            return nil
        end

        count = count + 1

        if count == 1 then
            v1 = value
        elseif count == 2 then
            v2 = value
        elseif count == 3 then
            v3 = value
        elseif count == 4 then
            v4 = value
        elseif count == 5 then
            v5 = value
        elseif count == 6 then
            v6 = value
        elseif count == 7 then
            v7 = value
        elseif count == 8 then
            v8 = value
        else
            return nil
        end
    end

    if count ~= 8 then
        return nil
    end

    return
        bit.bor(bit.lshift(v1, 16), v2),
        bit.bor(bit.lshift(v3, 16), v4),
        bit.bor(bit.lshift(v5, 16), v6),
        bit.bor(bit.lshift(v7, 16), v8)
end


---------------------------------------------------------------------
-- Parse IP
--
-- IPv4:
--   family, value
--
-- IPv6:
--   family, value1, value2, value3, value4
---------------------------------------------------------------------

local function parse_ip(ip)
    local v4 = ipv4_to_u32(ip)

    if v4 then
        return 4, v4
    end

    local v1, v2, v3, v4_2 =
        ipv6_to_u32(ip)

    if v1 then
        return 6, v1, v2, v3, v4_2
    end

    return nil
end


---------------------------------------------------------------------
-- CIDR parser
---------------------------------------------------------------------

local function parse_cidr(entry)
    local ip, prefix =
        entry:match("^([^/]+)/(%d+)$")

    if not ip then
        ip = entry
    else
        prefix = tonumber(prefix)
    end

    -----------------------------------------------------------------
    -- IPv4
    -----------------------------------------------------------------

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
            mask = bit.lshift(
                0xffffffff,
                32 - prefix
            )
        end

        return {
            family = 4,
            network = bit.band(v4, mask),
            mask = mask,
            prefix = prefix
        }
    end

    -----------------------------------------------------------------
    -- IPv6
    -----------------------------------------------------------------

    local v1, v2, v3, v4_2 =
        ipv6_to_u32(ip)

    if v1 then
        prefix = prefix or 128

        if prefix < 0 or prefix > 128 then
            return nil
        end

        local n1 = v1
        local n2 = v2
        local n3 = v3
        local n4 = v4_2

        local full = math.floor(prefix / 32)
        local remain = prefix % 32

        if full == 0 then
            n1 = 0
            n2 = 0
            n3 = 0
            n4 = 0

        elseif full == 1 then
            n2 = 0
            n3 = 0
            n4 = 0

        elseif full == 2 then
            n3 = 0
            n4 = 0

        elseif full == 3 then
            n4 = 0
        end

        if remain > 0 then
            local mask = bit.lshift(
                0xffffffff,
                32 - remain
            )

            if full == 0 then
                n1 = bit.band(v1, mask)
            elseif full == 1 then
                n2 = bit.band(v2, mask)
            elseif full == 2 then
                n3 = bit.band(v3, mask)
            elseif full == 3 then
                n4 = bit.band(v4_2, mask)
            end
        end

        return {
            family = 6,
            network1 = n1,
            network2 = n2,
            network3 = n3,
            network4 = n4,
            prefix = prefix
        }
    end

    return nil
end


---------------------------------------------------------------------
-- IPv6 matcher
---------------------------------------------------------------------

local function ipv6_match(
    value1,
    value2,
    value3,
    value4,
    rule
)
    local prefix = rule.prefix

    if prefix == 0 then
        return true
    end

    if prefix <= 32 then
        local mask = bit.lshift(
            0xffffffff,
            32 - prefix
        )

        return bit.band(value1, mask)
            == bit.band(rule.network1, mask)
    end

    if value1 ~= rule.network1 then
        return false
    end

    if prefix <= 64 then
        local remain = prefix - 32

        if remain == 0 then
            return true
        end

        local mask = bit.lshift(
            0xffffffff,
            32 - remain
        )

        return bit.band(value2, mask)
            == bit.band(rule.network2, mask)
    end

    if value2 ~= rule.network2 then
        return false
    end

    if prefix <= 96 then
        local remain = prefix - 64

        if remain == 0 then
            return true
        end

        local mask = bit.lshift(
            0xffffffff,
            32 - remain
        )

        return bit.band(value3, mask)
            == bit.band(rule.network3, mask)
    end

    if value3 ~= rule.network3 then
        return false
    end

    if prefix == 128 then
        return value4 == rule.network4
    end

    local remain = prefix - 96

    if remain == 0 then
        return true
    end

    local mask = bit.lshift(
        0xffffffff,
        32 - remain
    )

    return bit.band(value4, mask)
        == bit.band(rule.network4, mask)
end


---------------------------------------------------------------------
-- Whitelist matcher
---------------------------------------------------------------------

local function is_whitelisted_parsed(
    family,
    value1,
    value2,
    value3,
    value4
)
    if family == 4 then
        for i = 1, #whitelist_v4 do
            local rule = whitelist_v4[i]

            if bit.band(value1, rule.mask)
                == rule.network then
                return true
            end
        end

        return false
    end

    if family == 6 then
        for i = 1, #whitelist_v6 do
            if ipv6_match(
                value1,
                value2,
                value3,
                value4,
                whitelist_v6[i]
            ) then
                return true
            end
        end
    end

    return false
end


---------------------------------------------------------------------
-- Request IP cache
---------------------------------------------------------------------

local function get_client()
    if ngx_ctx.security_ip_checked then
        return
            ngx_ctx.security_ip,
            ngx_ctx.security_family,
            ngx_ctx.security_v1,
            ngx_ctx.security_v2,
            ngx_ctx.security_v3,
            ngx_ctx.security_v4,
            ngx_ctx.security_whitelisted
    end

    local ip = ngx_var.remote_addr

    ngx_ctx.security_ip_checked = true
    ngx_ctx.security_ip = ip

    if not ip then
        ngx_ctx.security_whitelisted = true
        return nil
    end

    local family, v1, v2, v3, v4 =
        parse_ip(ip)

    if not family then
        ngx_ctx.security_whitelisted = true
        return ip
    end

    ngx_ctx.security_family = family
    ngx_ctx.security_v1 = v1
    ngx_ctx.security_v2 = v2
    ngx_ctx.security_v3 = v3
    ngx_ctx.security_v4 = v4

    ngx_ctx.security_whitelisted =
        is_whitelisted_parsed(
            family,
            v1,
            v2,
            v3,
            v4
        )

    return
        ip,
        family,
        v1,
        v2,
        v3,
        v4,
        ngx_ctx.security_whitelisted
end


---------------------------------------------------------------------
-- Shared dictionary
---------------------------------------------------------------------

local function get_dict()
    return ngx.shared.security
end


local function ban_key(ip)
    return "ban:" .. ip
end


local function count_key(status, ip)
    return "count:" .. status .. ":" .. ip
end


---------------------------------------------------------------------
-- Clear all counters
---------------------------------------------------------------------

local function clear_counters(dict, ip)
    for status in pairs(CONFIG.rules) do
        dict:delete(
            count_key(status, ip)
        )
    end
end


---------------------------------------------------------------------
-- Ban
---------------------------------------------------------------------

local function get_ban(dict, ip)
    local key = ban_key(ip)
    local expires = dict:get(key)

    if not expires then
        return false
    end

    local now = ngx_now()

    if expires <= now then
        dict:delete(key)
        return false
    end

    return true, expires
end


---------------------------------------------------------------------
-- Init
---------------------------------------------------------------------

function _M.init()
    whitelist_v4 = {}
    whitelist_v6 = {}

    for _, entry in ipairs(CONFIG.whitelist or {}) do
        local rule = parse_cidr(entry)

        if not rule then
            ngx_log(
                ERR,
                "invalid whitelist entry: ",
                entry
            )

        elseif rule.family == 4 then
            whitelist_v4[#whitelist_v4 + 1] = rule

        else
            whitelist_v6[#whitelist_v6 + 1] = rule
        end
    end
end


---------------------------------------------------------------------
-- Access phase
---------------------------------------------------------------------

function _M.access()
    if not CONFIG.enabled then
        return
    end

    local ip, _, _, _, _, _, whitelisted =
        get_client()

    if not ip or whitelisted then
        return
    end

    local dict = get_dict()

    if get_ban(dict, ip) then
        return ngx_exit(HTTP_FORBIDDEN)
    end
end


---------------------------------------------------------------------
-- Log phase
---------------------------------------------------------------------

function _M.log()
    if not CONFIG.enabled then
        return
    end

    local status = ngx.status
    local rule = CONFIG.rules[status]

    if not rule then
        return
    end

    local ip, _, _, _, _, _, whitelisted =
        get_client()

    if not ip or whitelisted then
        return
    end

    local dict = get_dict()

    if get_ban(dict, ip) then
        return
    end

    local key = count_key(status, ip)

    local count, err = dict:incr(
        key,
        1,
        0,
        rule.window
    )

    if not count then
        ngx_log(
            ERR,
            "security counter failed: ",
            err or "unknown error"
        )

        return
    end

    if count < rule.count then
        return
    end

    local expires = ngx_now() + rule.ban

    local ok, set_err = dict:set(
        ban_key(ip),
        expires,
        rule.ban
    )

    if not ok then
        ngx_log(
            ERR,
            "security ban failed: ",
            set_err or "unknown error",
            " ip=",
            ip
        )

        return
    end

    clear_counters(dict, ip)

    ngx_log(
        WARN,
        "security ban ip=",
        ip,
        " status=",
        status,
        " count=",
        count,
        " ban=",
        rule.ban,
        "s"
    )
end


---------------------------------------------------------------------
-- Manual ban
---------------------------------------------------------------------

function _M.ban(ip, duration)
    if not ip or ip == "" then
        return false
    end

    local family, v1, v2, v3, v4 =
        parse_ip(ip)

    if not family then
        return false
    end

    duration = tonumber(duration) or 1800

    if duration <= 0 then
        return false
    end

    if is_whitelisted_parsed(
        family,
        v1,
        v2,
        v3,
        v4
    ) then
        return false
    end

    local dict = get_dict()

    local ok = dict:set(
        ban_key(ip),
        ngx_now() + duration,
        duration
    )

    if not ok then
        return false
    end

    clear_counters(dict, ip)

    ngx_log(
        WARN,
        "security manual ban ip=",
        ip,
        " ban=",
        duration,
        "s"
    )

    return true
end


---------------------------------------------------------------------
-- Manual unban
---------------------------------------------------------------------

function _M.unban(ip)
    if not ip or ip == "" then
        return false
    end

    local family = parse_ip(ip)

    if not family then
        return false
    end

    local dict = get_dict()

    dict:delete(ban_key(ip))
    clear_counters(dict, ip)

    ngx_log(
        INFO,
        "security unban ip=",
        ip
    )

    return true
end


---------------------------------------------------------------------
-- JSON response
---------------------------------------------------------------------

local function json_response(status, data)
    ngx.header.content_type =
        "application/json; charset=utf-8"

    ngx.status = status or HTTP_OK

    local json_str, err =
        cjson.encode(data)

    if not json_str then
        ngx_log(
            ERR,
            "security json encode error: ",
            err or "unknown error"
        )

        ngx.status =
            HTTP_INTERNAL_SERVER_ERROR

        ngx.say(
            '{"success":false,"error":"json encode failed"}'
        )

        return
    end

    ngx.say(json_str)
end


---------------------------------------------------------------------
-- Status
---------------------------------------------------------------------

function _M.status()
    local dict = get_dict()
    local now = ngx_now()

    local banned = {}
    local counters = {}

    local keys = dict:get_keys(0)

    for i = 1, #keys do
        local key = keys[i]

        if key:sub(1, 4) == "ban:" then
            local ip = key:sub(5)
            local expires = dict:get(key)

            if expires and expires > now then
                banned[#banned + 1] = {
                    ip = ip,
                    expires = expires,
                    remaining =
                        math.floor(expires - now)
                }
            end

        elseif key:sub(1, 6) == "count:" then
            local status, ip =
                key:match("^count:(%d+):(.+)$")

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

    local rules = {}

    for status, cfg in pairs(CONFIG.rules) do
        rules[#rules + 1] = {
            status = status,
            count = cfg.count,
            window = cfg.window,
            ban = cfg.ban
        }
    end

    return {
        enabled = CONFIG.enabled,
        rules = rules,
        whitelist = CONFIG.whitelist,
        banned = banned,
        counters = counters
    }
end


---------------------------------------------------------------------
-- JSON status
---------------------------------------------------------------------

function _M.status_json()
    json_response(
        HTTP_OK,
        _M.status()
    )
end


---------------------------------------------------------------------
-- JSON ban
---------------------------------------------------------------------

function _M.ban_json(ip)
    local args = ngx.req.get_uri_args()
    local duration =
        tonumber(args.duration) or 1800

    if _M.ban(ip, duration) then
        return json_response(
            HTTP_OK,
            {
                success = true,
                ip = ip,
                duration = duration
            }
        )
    end

    json_response(
        HTTP_BAD_REQUEST,
        {
            success = false,
            error = "invalid ip or whitelisted ip"
        }
    )
end


---------------------------------------------------------------------
-- JSON unban
---------------------------------------------------------------------

function _M.unban_json(ip)
    if _M.unban(ip) then
        return json_response(
            HTTP_OK,
            {
                success = true,
                ip = ip
            }
        )
    end

    json_response(
        HTTP_BAD_REQUEST,
        {
            success = false,
            error = "invalid ip"
        }
    )
end


return _M
