local import = ...
local native = import("compat").native

local M = {}

-- Floored modulo of a by b. Like Lua's %, the result takes the sign of
-- b. Lua 5.4 and LuaJIT round float % differently (1 % 0.1 is 0.0999..
-- on one and 0 on the other), while mod gives Lua 5.4's exact result on
-- both. Use it instead of % when an operand can be a non-integer float
-- and the output must match across Lua flavours. Integer operands agree
-- either way. The result is always a float.
M.mod = native.mod

-- Linear interpolation between a and b by t.
function M.lerp(a, b, t)
    return a + (b - a) * t
end

-- Map a value from one range to another.
function M.mapRange(v, inLo, inHi, outLo, outHi)
    return outLo + ((v - inLo) / (inHi - inLo)) * (outHi - outLo)
end

-- Clamp v to the range [lo, hi].
function M.clamp(v, lo, hi)
    return math.min(hi, math.max(lo, v))
end

-- Euclidean distance between two points.
function M.dist(a, b)
    return math.sqrt((b[1] - a[1])^2 + (b[2] - a[2])^2)
end

-- Angle in radians from point a to point b.
function M.angle(a, b)
    return math.atan(b[2] - a[2], b[1] - a[1])
end

-- Normalize a 2D vector to unit length.
function M.norm(v)
    local len = math.sqrt(v[1]^2 + v[2]^2)
    if len == 0 then return {0, 0} end
    return {v[1] / len, v[2] / len}
end

-- Convert radians to degrees.
function M.degrees(rad)
    return rad * 180 / math.pi
end

-- Convert degrees to radians.
function M.radians(deg)
    return deg * math.pi / 180
end

return M
