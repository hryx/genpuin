-- Noise. Perlin (improved, Ken Perlin 2002) keeps its permutation table in
-- Zig, one per Lua state. Simplex, value, worley and curl noise and
-- noiseGrid take the same noise seed as an integer.

local import = ...
local core = import("core")
local native = import("compat").native

local algo = core.algo
local T = core.texture

local M = {}

local perlin = native.perlin
local fbm = native.fbm

local seed = core.vary * 1000003

-- Seed every noise kind: the Perlin table, and simplex, valueNoise, worley,
-- curl, curlFlow and noiseGrid calls without opts.seed.
-- With --vary N on the command line, N is mixed into every seed, and a
-- script that never seeds behaves as if it called seed(0).
function M.seed(n)
    algo.noiseSeed(n)
    seed = n + core.vary * 1000003
end

-- 2D Perlin noise, returns a value in approximately [-1, 1].
M.perlin = perlin

-- Fractal Brownian motion (layered Perlin noise).
-- octaves default 6, lacunarity 2, gain 0.5.
function M.fbm(x, y, octaves, lacunarity, gain)
    return fbm(x, y, octaves or 6, lacunarity or 2.0, gain or 0.5)
end

-- 2D simplex noise at (x, y), or 3D when z is given. Returns about -1..1.
function M.simplex(x, y, z)
    return T.simplex(seed, x, y, z)
end

-- Value noise at (x, y), or 3D when z is given. Returns -1..1.
function M.valueNoise(x, y, z)
    return T.valueNoise(seed, x, y, z)
end

-- Worley (cellular) noise at (x, y). Returns F1 and F2, the distances to
-- the nearest and second nearest feature points, so F2 - F1 traces cell
-- edges. opts.metric is "euclidean" (default), "manhattan" or "chebyshev".
-- opts.jitter 0..1 is how far points stray from cell centers (default 1).
function M.worley(x, y, opts)
    return T.worley(seed, x, y, opts)
end

-- Curl of simplex noise at (x, y): a divergence free vector dx, dy.
-- opts takes the noiseGrid noise options (kind, octaves, fractal, warp...)
-- plus scale (default 1), offset = {x, y} and z.
function M.curl(x, y, opts)
    return T.curl(seed, x, y, opts)
end

-- A Field of noise, w x h cells.
-- opts.kind: "simplex" (default), "perlin", "value", "worley", or
--   "worleyEdge" for F2 - F1. opts.metric and opts.jitter apply to worley.
-- opts.scale: noise frequency per scene unit (default 0.01).
-- opts.offset = {x, y} shifts the noise. opts.z samples the 3D form (worley stays 2D).
-- opts.octaves (default 1), lacunarity (2), gain (0.5).
-- opts.fractal: "fbm" (default), "ridged" or "turbulence".
-- opts.warp: domain warp strength in noise units, opts.warpScale its frequency,
--   opts.warpOctaves its octaves (default octaves), opts.warpDepth 1 to 4
--   warps the warp noise again for more swirl (default 1).
-- opts.x, y, w, h: the scene rect the grid covers (default one unit per
--   cell), so a grid of any resolution samples the same scene noise.
-- opts.seed (default the noise seed).
function M.noiseGrid(w, h, opts)
    return T.noiseGrid(w, h, opts or {}, seed)
end

-- A flow field of curl noise for gen.trace. Its sample(x, y) returns an
-- angle. opts as for curl, with scale defaulting to 0.005, and opts.seed
-- (default the noise seed).
function M.curlFlow(opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.scale == nil then o.scale = 0.005 end
    local s = o.seed or seed
    return {type = "flow", sample = function(x, y) return T.curlAngle(s, x, y, o) end}
end

return M
