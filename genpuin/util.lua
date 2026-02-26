local M = {}

function M.lerp(a, b, t)
    return a + (b - a) * t
end

function M.mapRange(v, inLo, inHi, outLo, outHi)
    return outLo + ((v - inLo) / (inHi - inLo)) * (outHi - outLo)
end

function M.clamp(v, lo, hi)
    return math.min(hi, math.max(lo, v))
end

function M.dist(a, b)
    return math.sqrt((b[1] - a[1])^2 + (b[2] - a[2])^2)
end

function M.angle(a, b)
    return math.atan(b[2] - a[2], b[1] - a[1])
end

function M.norm(v)
    local len = math.sqrt(v[1]^2 + v[2]^2)
    if len == 0 then return {0, 0} end
    return {v[1] / len, v[2] / len}
end

function M.degrees(rad)
    return rad * 180 / math.pi
end

function M.radians(deg)
    return deg * math.pi / 180
end

return M
