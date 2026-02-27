local util = require("genpuin.util")

local M = {}

function M.rgb(r, g, b)
    return {r, g, b, 1}
end

function M.rgba(r, g, b, a)
    return {r, g, b, a}
end

function M.hsv(h, s, v)
    h = (h % 1) * 6
    local i = math.floor(h)
    local f = h - i
    local p = v * (1 - s)
    local q = v * (1 - s * f)
    local t = v * (1 - s * (1 - f))
    local sector = i % 6
    if sector == 0 then return {v, t, p, 1}
    elseif sector == 1 then return {q, v, p, 1}
    elseif sector == 2 then return {p, v, t, 1}
    elseif sector == 3 then return {p, q, v, 1}
    elseif sector == 4 then return {t, p, v, 1}
    else return {v, p, q, 1}
    end
end

function M.hsl(h, s, l)
    h = h % 1
    local function hue2rgb(p, q, t)
        if t < 0 then t = t + 1 end
        if t > 1 then t = t - 1 end
        if t < 1/6 then return p + (q - p) * 6 * t end
        if t < 1/2 then return q end
        if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
        return p
    end
    if s == 0 then
        return {l, l, l, 1}
    end
    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    return {
        hue2rgb(p, q, h + 1/3),
        hue2rgb(p, q, h),
        hue2rgb(p, q, h - 1/3),
        1,
    }
end

function M.hex(str)
    if str:sub(1, 1) == "#" then str = str:sub(2) end
    local r = tonumber(str:sub(1, 2), 16) / 255
    local g = tonumber(str:sub(3, 4), 16) / 255
    local b = tonumber(str:sub(5, 6), 16) / 255
    local a = 1
    if #str >= 8 then
        a = tonumber(str:sub(7, 8), 16) / 255
    end
    return {r, g, b, a}
end

function M.lerpColor(c1, c2, t)
    return {
        util.lerp(c1[1], c2[1], t),
        util.lerp(c1[2], c2[2], t),
        util.lerp(c1[3], c2[3], t),
        util.lerp(c1[4], c2[4], t),
    }
end

function M.darken(c, amount)
    return {c[1] * (1 - amount), c[2] * (1 - amount), c[3] * (1 - amount), c[4]}
end

function M.lighten(c, amount)
    return {
        c[1] + (1 - c[1]) * amount,
        c[2] + (1 - c[2]) * amount,
        c[3] + (1 - c[3]) * amount,
        c[4],
    }
end

function M.withAlpha(c, a)
    return {c[1], c[2], c[3], a}
end

function M.toSvg(c)
    if type(c) == "string" then return c end
    if type(c) == "table" and c.type and c.id then
        return string.format("url(#%s)", c.id)
    end
    return string.format("rgb(%d,%d,%d)",
        math.floor(c[1] * 255 + 0.5),
        math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5))
end

return M
