-- 2D Perlin noise (improved, Ken Perlin 2002). The permutation table is
-- kept in Zig, one per Lua state.

local algo = require("genpuin.core").algo
local native = require("genpuin.compat").native

local M = {}

local perlin = native.perlin
local fbm = native.fbm

-- Seed the noise permutation table.
-- With --vary N on the command line, N is mixed into every seed, and a
-- script that never seeds behaves as if it called seed(0).
M.seed = algo.noiseSeed

-- 2D Perlin noise, returns a value in approximately [-1, 1].
M.perlin = perlin

-- Fractal Brownian motion (layered Perlin noise).
-- octaves default 6, lacunarity 2, gain 0.5.
function M.fbm(x, y, octaves, lacunarity, gain)
    return fbm(x, y, octaves or 6, lacunarity or 2.0, gain or 0.5)
end

return M
