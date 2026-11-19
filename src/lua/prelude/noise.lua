-- Noise. Perlin (improved, Ken Perlin 2002) keeps its permutation table in
-- Zig, one per Lua state, next to the noise seed that simplex, value,
-- worley and curl noise and noiseGrid read when given no seed.

local import = ...
local core = import("core")
local native = import("compat").native

local algo = core.algo
local T = core.texture

local M = {}

local perlin = native.perlin
local fbm = native.fbm

-- Seed every noise kind: the Perlin table, and simplex, valueNoise, worley,
-- curl, curlFlow and noiseGrid calls without opts.seed. Seeds are whole
-- numbers from 0 to 4294967295. Call it at most once, before any of those
-- functions. A script that never calls it runs as noiseSeed(0).
-- With --noise-seed N on the command line, the call acts as noiseSeed(N),
-- and a script that never seeds runs as noiseSeed(N).
M.seed = algo.noiseSeed

-- 2D Perlin noise, returns a value in approximately [-1, 1].
M.perlin = perlin

-- Fractal Brownian motion (layered Perlin noise).
-- octaves default 6, lacunarity 2, gain 0.5.
function M.fbm(x, y, octaves, lacunarity, gain)
    return fbm(x, y, octaves or 6, lacunarity or 2.0, gain or 0.5)
end

-- 2D simplex noise at (x, y), or 3D when z is given. Returns about -1..1.
function M.simplex(x, y, z)
    return T.simplex(nil, x, y, z)
end

-- Value noise at (x, y), or 3D when z is given. Returns -1..1.
function M.valueNoise(x, y, z)
    return T.valueNoise(nil, x, y, z)
end

-- Worley (cellular) noise at (x, y). Returns F1 and F2, the distances to
-- the nearest and second nearest feature points, so F2 - F1 traces cell
-- edges. opts.metric is "euclidean" (default), "manhattan" or "chebyshev".
-- opts.jitter 0..1 is how far points stray from cell centers (default 1).
function M.worley(x, y, opts)
    return T.worley(nil, x, y, opts)
end

-- Curl of simplex noise at (x, y): a divergence free vector dx, dy.
-- opts takes the noiseGrid noise options (kind, octaves, fractal, warp...)
-- plus scale (default 1), offset = {x, y} and z. The noise is sampled at
-- (x * scale + offset[1], y * scale + offset[2]) and opts.z picks a slice
-- of its 3D form, so moving z animates the field. The vector is the noise
-- gradient per noise unit turned a quarter turn, not a unit vector, and
-- scale does not shrink it. For one octave of simplex its length
-- averages about 3.3 and peaks near 7.5, for perlin about 1.2 and 3.
-- More octaves raise the peaks. Normalize it, or take gen.curlFlow, when
-- only the direction matters. Noise coordinates are 32-bit floats, so
-- past about 8000 the vector turns noisy.
function M.curl(x, y, opts)
    return T.curl(nil, x, y, opts)
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
    return T.noiseGrid(w, h, opts or {})
end

-- A flow field of curl noise for gen.trace. Its sample(x, y) returns an
-- angle. opts as for curl, with scale defaulting to 0.005, and opts.seed
-- (default the noise seed).
function M.curlFlow(opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.scale == nil then o.scale = 0.005 end
    return {type = "flow", sample = function(x, y) return T.curlAngle(o.seed, x, y, o) end}
end

return M
