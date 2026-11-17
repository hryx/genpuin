-- Portability between Lua versions.
--
-- band, bxor, rshift and lshift operate on 32-bit unsigned integers held
-- in Lua numbers and give the same results on every Lua version.
--
-- native holds the core.algo functions that scripts call in hot loops.
-- On LuaJIT they are FFI calls into Zig, which compiled traces make
-- directly. Elsewhere they are the plain core.algo functions.

local import = ...
local algo = import("core").algo

local M = {}

-- Bitwise and of two 32-bit unsigned integers.
M.band = algo.band

-- Bitwise exclusive or of two 32-bit unsigned integers.
M.bxor = algo.bxor

-- Logical right shift of a 32-bit unsigned integer by n bits.
M.rshift = algo.rshift

-- Left shift of a 32-bit unsigned integer by n bits, wrapping at 32 bits.
M.lshift = algo.lshift

local native = {
    rand = algo.rand,
    randRange = algo.randRange,
    randInt = algo.randInt,
    gaussian = algo.gaussian,
    perlin = algo.perlin,
    fbm = algo.fbm,
    mod = algo.mod,
}

if rawget(_G, "jit") then
    local ok, ffi = pcall(require, "ffi")
    if ok then
        local p = algo.ffi()
        local st = ffi.cast("void *", p.state)
        local rand = ffi.cast("double (*)(void *)", p.rand)
        local randRange = ffi.cast("double (*)(void *, double, double)", p.randRange)
        local randInt = ffi.cast("double (*)(void *, double, double)", p.randInt)
        local gaussian = ffi.cast("double (*)(void *, double, double)", p.gaussian)
        local perlin = ffi.cast("double (*)(void *, double, double)", p.perlin)
        local fbm = ffi.cast("double (*)(void *, double, double, double, double, double)", p.fbm)
        local mod = ffi.cast("double (*)(double, double)", p.mod)
        native.rand = function() return rand(st) end
        native.randRange = function(lo, hi) return randRange(st, lo, hi) end
        native.randInt = function(lo, hi) return randInt(st, lo, hi) end
        native.gaussian = function(mean, stddev) return gaussian(st, mean, stddev) end
        native.perlin = function(x, y) return perlin(st, x, y) end
        native.fbm = function(x, y, octaves, lacunarity, gain)
            return fbm(st, x, y, octaves, lacunarity, gain)
        end
        native.mod = function(a, b) return mod(a, b) end
    end
end

-- Hot core.algo entry points, see the top of this file.
M.native = native

return M
