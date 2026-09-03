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

local ERR = ngx.ERR
local WARN = ngx.WARN
local INFO = ngx.INFO

local HTTP_OK = ngx.HTTP_OK
local HTTP_FORBIDDEN = ngx.HTTP_FORBIDDEN
local HTTP_BAD_REQUEST = ngx.HTTP_BAD_REQUEST
local HTTP_INTERNAL_SERVER_ERROR =
    ngx.HTTP_INTERNAL_SERVER_ERROR


---------------------------------------------------------------------
-- Whitelist
--
-- Exact IPv4:
--   whitelist_v4_exact[u32] = true
--
-- Exact IPv6:
--   whitelist_v6_exact[v1][v2][v3][v4] = true
--
-- CIDR:
--   whitelist_v4_cidr
--   whitelist_v6_cidr
---------------------------------------------------------------------

local whitelist_v4_exact = {}
local whitelist_v6_exact = {}

local whitelist_v4_cidr = {}
local whitelist_v6_cidr = {}


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
-- IPv6 side parser
---------------------------------------------------------------------

local function parse_ipv6_side(side, out)
    if side == "" then
        return 0
    end

    local count = 0

    for part in side:gmatch("[^:]+") do
        local value = tonumber(part, 16)

        if not value or value > 0xffff then
            return nil
        end

        count = count + 1

        if count > 4 then
            return nil
        end

        out[count] = value
    end

    return count
end


---------------------------------------------------------------------
-- IPv6
--
-- Return:
--   uint32, uint32, uint32, uint32
---------------------------------------------------------------------

local function ipv6_to_u32(ip)
    if not ip:find(":", 1, true) then
        return nil
    end

    local left, right =
        ip:match("^(.-)::(.-)$")

    local g = {}

    if left then
        local left_values = {}
        local right_values = {}

        local lc =
            parse_ipv6_side(
                left,
                left_values
            )

        if not lc then
            return nil
        end

        local rc =
            parse_ipv6_side(
                right,
                right_values
            )

        if not rc then
            return nil
        end

        if lc + rc >= 8 then
            return nil
        end

        for i = 1, lc do
            g[i] = left_values[i]
        end

        local zero =
            8 - lc - rc

        for i = 1, zero do
            g[lc + i] = 0
        end

        for i = 1, rc do
            g[lc + zero + i] =
                right_values[i]
        end

    else
        local values = {}

        local count =
            parse_ipv6_side(
                ip,
                values
            )

        if count ~= 8 then
            return nil
        end

        for i = 1, 8 do
            g[i] = values[i]
        end
    end

    return
        bit.bor(
            bit.lshift(g[1] or 0, 16),
            g[2] or 0
        ),
        bit.bor(
            bit.lshift(g[3] or 0, 16),
            g[4] or 0
        ),
        bit.bor(
            bit.lshift(g[5] or 0, 16),
            g[6] or 0
        ),
        bit.bor(
            bit.lshift(g[7] or 0, 16),
            g[8] or 0
        )
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
    local v4 =
        ipv4_to_u32(ip)

    if v4 then
        return 4, v4
    end

    local v1, v2, v3, v4_2 =
        ipv6_to_u32(ip)

    if v1 then
        return
            6,
            v1,
            v2,
            v3,
            v4_2
    end

    return nil
end


---------------------------------------------------------------------
-- CIDR parser
---------------------------------------------------------------------

local function parse_cidr(entry)
    local ip, prefix =
        entry:match(
            "^([^/]+)/(%d+)$"
        )

    if not ip then
        ip = entry
    else
        prefix = tonumber(prefix)
    end


    -----------------------------------------------------------------
    -- IPv4
    -----------------------------------------------------------------

    local v4 =
        ipv4_to_u32(ip)

    if v4 then
        prefix = prefix or 32

        if prefix < 0 or prefix > 32 then
            return nil
        end

        if prefix == 32 then
            return {
                family = 4,
                exact = v4
            }
        end

        local mask

        if prefix == 0 then
            mask = 0
        else
            mask =
                bit.lshift(
                    0xffffffff,
                    32 - prefix
                )
        end

        return {
            family = 4,
            network = bit.band(
                v4,
                mask
            ),
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

        if prefix == 128 then
            return {
                family = 6,

                exact1 = v1,
                exact2 = v2,
                exact3 = v3,
                exact4 = v4_2
            }
        end

        local n1 = v1
        local n2 = v2
        local n3 = v3
        local n4 = v4_2

        local full =
            math.floor(prefix / 32)

        local remain =
            prefix % 32


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
            local mask =
                bit.lshift(
                    0xffffffff,
                    32 - remain
                )

            if full == 0 then
                n1 =
                    bit.band(
                        v1,
                        mask
                    )

            elseif full == 1 then
                n2 =
                    bit.band(
                        v2,
                        mask
                    )

            elseif full == 2 then
                n3 =
                    bit.band(
                        v3,
                        mask
                    )

            elseif full == 3 then
                n4 =
                    bit.band(
                        v4_2,
                        mask
                    )
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
    v1,
    v2,
    v3,
    v4,
    rule
)
    local prefix =
        rule.prefix


    if prefix == 0 then
        return true
    end


    if prefix <= 32 then
        local mask =
            bit.lshift(
                0xffffffff,
                32 - prefix
            )

        return
            bit.band(v1, mask)
            ==
            bit.band(
                rule.network1,
                mask
            )
    end


    if v1 ~= rule.network1 then
        return false
    end


    if prefix <= 64 then
        local remain =
            prefix - 32

        if remain == 0 then
            return true
        end

        local mask =
            bit.lshift(
                0xffffffff,
                32 - remain
            )

        return
            bit.band(v2, mask)
            ==
            bit.band(
                rule.network2,
                mask
            )
    end


    if v2 ~= rule.network2 then
        return false
    end


    if prefix <= 96 then
        local remain =
            prefix - 64

        if remain == 0 then
            return true
        end

        local mask =
            bit.lshift(
                0xffffffff,
                32 - remain
            )

        return
            bit.band(v3, mask)
            ==
            bit.band(
                rule.network3,
                mask
            )
    end


    if v3 ~= rule.network3 then
        return false
    end


    if prefix == 128 then
        return
            v4 == rule.network4
    end


    local remain =
        prefix - 96

    if remain == 0 then
        return true
    end

    local mask =
        bit.lshift(
            0xffffffff,
            32 - remain
        )

    return
        bit.band(v4, mask)
        ==
        bit.band(
            rule.network4,
            mask
        )
end


---------------------------------------------------------------------
-- Whitelist matcher
---------------------------------------------------------------------

local function is_whitelisted(
    family,
    v1,
    v2,
    v3,
    v4
)
    -----------------------------------------------------------------
    -- IPv4
    -----------------------------------------------------------------

    if family == 4 then
        if whitelist_v4_exact[v1] then
            return true
        end

        for i = 1, #whitelist_v4_cidr do
            local rule =
                whitelist_v4_cidr[i]

            if bit.band(
                v1,
                rule.mask
            ) == rule.network then
                return true
            end
        end

        return false
    end


    -----------------------------------------------------------------
    -- IPv6
    -----------------------------------------------------------------

    if family == 6 then
        local t1 =
            whitelist_v6_exact[v1]

        if t1 then
            local t2 =
                t1[v2]

            if t2 then
                local t3 =
                    t2[v3]

                if t3 and t3[v4] then
                    return true
                end
            end
        end


        for i = 1, #whitelist_v6_cidr do
            if ipv6_match(
                v1,
                v2,
                v3,
                v4,
                whitelist_v6_cidr[i]
            ) then
                return true
            end
        end
    end

    return false
end


---------------------------------------------------------------------
-- Client IP
--
-- IMPORTANT:
-- ngx.ctx / ngx.var are accessed here only.
--
-- Do NOT move these references to module scope.
---------------------------------------------------------------------

local function get_client()
    local ctx = ngx.ctx

    if ctx.security_ip_checked then
        return
            ctx.security_ip,
            ctx.security_family,
            ctx.security_v1,
            ctx.security_v2,
            ctx.security_v3,
            ctx.security_v4,
            ctx.security_whitelisted
    end


    local ip =
        ngx.var.remote_addr

    ctx.security_ip_checked = true
    ctx.security_ip = ip


    if not ip then
        ctx.security_whitelisted = true
        return nil
    end


    local family, v1, v2, v3, v4 =
        parse_ip(ip)


    if not family then
        ctx.security_whitelisted = true
        return ip
    end


    local whitelisted =
        is_whitelisted(
            family,
            v1,
            v2,
            v3,
            v4
        )


    ctx.security_family = family
    ctx.security_v1 = v1
    ctx.security_v2 = v2
    ctx.security_v3 = v3
    ctx.security_v4 = v4
    ctx.security_whitelisted =
        whitelisted


    return
        ip,
        family,
        v1,
        v2,
        v3,
        v4,
        whitelisted
end


---------------------------------------------------------------------
-- Clear counters
---------------------------------------------------------------------

local function clear_counters(
    dict,
    ip
)
    for status in pairs(CONFIG.rules) do
        dict:delete(
            "count:"
                .. status
                .. ":"
                .. ip
        )
    end
end


---------------------------------------------------------------------
-- Init
--
-- Safe to call from init_by_lua.
---------------------------------------------------------------------

function _M.init()
    whitelist_v4_exact = {}
    whitelist_v6_exact = {}

    whitelist_v4_cidr = {}
    whitelist_v6_cidr = {}


    for _, entry in
        ipairs(CONFIG.whitelist or {})
    do
        local rule =
            parse_cidr(entry)


        if not rule then
            ngx_log(
                ERR,
                "invalid whitelist entry: ",
                entry
            )


        elseif rule.family == 4 then
            if rule.exact then
                whitelist_v4_exact[
                    rule.exact
                ] = true
            else
                whitelist_v4_cidr[
                    #whitelist_v4_cidr + 1
                ] = rule
            end


        elseif rule.family == 6 then
            if rule.exact1 then
                local t1 =
                    whitelist_v6_exact[
                        rule.exact1
                    ]

                if not t1 then
                    t1 = {}

                    whitelist_v6_exact[
                        rule.exact1
                    ] = t1
                end


                local t2 =
                    t1[rule.exact2]

                if not t2 then
                    t2 = {}

                    t1[rule.exact2] =
                        t2
                end


                local t3 =
                    t2[rule.exact3]

                if not t3 then
                    t3 = {}

                    t2[rule.exact3] =
                        t3
                end


                t3[rule.exact4] = true

            else
                whitelist_v6_cidr[
                    #whitelist_v6_cidr + 1
                ] = rule
            end
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


    local dict =
        ngx.shared.security

    local key =
        "ban:" .. ip

    local expires =
        dict:get(key)


    if not expires then
        return
    end


    if expires > ngx_now() then
        return ngx_exit(
            HTTP_FORBIDDEN
        )
    end


    dict:delete(key)
end


---------------------------------------------------------------------
-- Log phase
---------------------------------------------------------------------

function _M.log()
    if not CONFIG.enabled then
        return
    end


    local status =
        ngx.status

    local rule =
        CONFIG.rules[status]


    if not rule then
        return
    end


    local ip, _, _, _, _, _, whitelisted =
        get_client()


    if not ip or whitelisted then
        return
    end


    local dict =
        ngx.shared.security


    ---------------------------------------------------------------
    -- Check existing ban
    ---------------------------------------------------------------

    local ban_key =
        "ban:" .. ip

    local ban_expires =
        dict:get(ban_key)


    if ban_expires then
        if ban_expires > ngx_now() then
            return
        end

        dict:delete(ban_key)
    end


    ---------------------------------------------------------------
    -- Increment counter
    ---------------------------------------------------------------

    local key =
        "count:"
            .. status
            .. ":"
            .. ip


    local count, err =
        dict:incr(
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


    ---------------------------------------------------------------
    -- Ban
    --
    -- add() prevents another worker from
    -- overwriting an existing ban.
    ---------------------------------------------------------------

    local expires =
        ngx_now() + rule.ban


    local ok, set_err =
        dict:add(
            ban_key,
            expires,
            rule.ban
        )


    if not ok then
        return
    end


    ---------------------------------------------------------------
    -- Clear counters
    ---------------------------------------------------------------

    clear_counters(
        dict,
        ip
    )


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

function _M.ban(
    ip,
    duration
)
    if not ip or ip == "" then
        return false
    end


    local family, v1, v2, v3, v4 =
        parse_ip(ip)


    if not family then
        return false
    end


    duration =
        tonumber(duration) or 1800


    if duration <= 0 then
        return false
    end


    if is_whitelisted(
        family,
        v1,
        v2,
        v3,
        v4
    ) then
        return false
    end


    local dict =
        ngx.shared.security


    local key =
        "ban:" .. ip


    local ok =
        dict:set(
            key,
            ngx_now() + duration,
            duration
        )


    if not ok then
        return false
    end


    clear_counters(
        dict,
        ip
    )


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


    local family =
        parse_ip(ip)


    if not family then
        return false
    end


    local dict =
        ngx.shared.security


    dict:delete(
        "ban:" .. ip
    )


    clear_counters(
        dict,
        ip
    )


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

local function json_response(
    status,
    data
)
    ngx.header.content_type =
        "application/json; charset=utf-8"


    ngx.status =
        status or HTTP_OK


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
    local dict =
        ngx.shared.security

    local now =
        ngx_now()


    local banned = {}
    local counters = {}


    local keys =
        dict:get_keys(0)


    for i = 1, #keys do
        local key =
            keys[i]


        -------------------------------------------------------------
        -- Ban
        -------------------------------------------------------------

        if key:sub(1, 4) == "ban:" then
            local ip =
                key:sub(5)

            local expires =
                dict:get(key)


            if expires and expires > now then
                banned[
                    #banned + 1
                ] = {
                    ip = ip,

                    expires = expires,

                    remaining =
                        math.floor(
                            expires - now
                        )
                }
            end


        -------------------------------------------------------------
        -- Counter
        -------------------------------------------------------------

        elseif key:sub(1, 6) == "count:" then
            local status, ip =
                key:match(
                    "^count:(%d+):(.+)$"
                )


            if status and ip then
                local count =
                    dict:get(key)


                if count then
                    counters[
                        #counters + 1
                    ] = {
                        status =
                            tonumber(status),

                        ip = ip,

                        count = count
                    }
                end
            end
        end
    end


    ---------------------------------------------------------------
    -- Rules
    ---------------------------------------------------------------

    local rules = {}


    for status, cfg in
        pairs(CONFIG.rules)
    do
        rules[
            #rules + 1
        ] = {
            status = status,

            count = cfg.count,

            window = cfg.window,

            ban = cfg.ban
        }
    end


    return {
        enabled = CONFIG.enabled,

        rules = rules,

        whitelist =
            CONFIG.whitelist,

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
    local args =
        ngx.req.get_uri_args()


    local duration =
        tonumber(
            args.duration
        ) or 1800


    if _M.ban(
        ip,
        duration
    ) then
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

            error =
                "invalid ip or whitelisted ip"
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
