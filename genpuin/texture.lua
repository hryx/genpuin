-- Noise and density textures backed by core.texture.
-- Scalar samplers (simplex, worley, valueNoise, curl) read the seed set by
-- textureSeed. Bulk functions return Fields to draw with gen.image.

local core = require("genpuin.core")
local rand = require("genpuin.rand")

local T = core.texture

local M = {}

local seed = core.vary * 1000003

local function randomSeed()
    return rand.randInt(1, 2147483646)
end

local function withDefault(opts, key, value)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o[key] == nil then o[key] = value end
    return o
end

-- Set the seed for simplex, worley, valueNoise, curl, curlFlow and for
-- noiseGrid calls without opts.seed. With --vary N, N is mixed in.
function M.textureSeed(n)
    seed = n + core.vary * 1000003
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
-- opts.seed (default the textureSeed).
function M.noiseGrid(w, h, opts)
    return T.noiseGrid(w, h, opts or {}, seed)
end

-- A flow field of curl noise for gen.trace. Its sample(x, y) returns an
-- angle. opts as for curl, with scale defaulting to 0.005, and opts.seed.
function M.curlFlow(opts)
    local o = withDefault(opts, "scale", 0.005)
    local s = o.seed or seed
    return {type = "flow", sample = function(x, y) return T.curlAngle(s, x, y, o) end}
end

-- Trace many particles at once. Returns a list of point lists, one per
-- start, each beginning at its start point.
-- opts.field: an angle Field to follow, stretched over opts.bounds. Without
--   it the particles follow curl noise (noise options as for curl, scale
--   default 0.005).
-- opts.starts: list of {x, y}, or opts.n (default 500) random starts in bounds.
-- opts.bounds = {x, y, w, h}: paths stop when they leave it (opts.clip = false
--   keeps going). Defaults to the field's cell size when a field is given.
-- opts.steps (default 200), opts.stepSize (default 1, negative goes upstream).
-- opts.seed places the random starts and seeds the noise.
function M.traceFlow(opts)
    return T.traceFlow(opts, randomSeed())
end

-- Gaussian blur of a Field. radius is the standard deviation in cells.
-- Returns a new Field.
function M.blurField(f, radius)
    return T.blur(f, radius)
end

-- Per-cell central difference gradient of a Field. Returns two Fields, dx and dy.
function M.fieldGradient(f)
    return T.gradient(f)
end

-- Render a strange attractor into a density Field. Draw it with
-- gen.image(f, x, y, w, h, {palette = ..., tone = "log"}).
-- opts.kind: "clifford" (default), "dejong", "svensson", "bedhead",
--   "hopalong", "gumowskiMira", "tinkerbell", "ikeda", "fractalDream",
--   "symmetricIcon". opts.a, b, c, d (and e, degree for symmetricIcon)
--   default to a known good set per kind.
-- opts.n iterations (default 2e6), opts.w, h grid size (default 800).
-- opts.supersample: render at n times the size and sum down (default 1).
-- opts.splat: "bilinear" (default) or "nearest".
-- opts.bounds = {x, y, w, h} in map space, fitted from a pilot run if absent.
-- opts.seed (default from gen.rand).
function M.attractor(opts)
    return T.attractor(opts or {}, randomSeed())
end

-- Render a fractal flame (Draves and Reckase). Returns two Fields: density,
-- and the average color coordinate 0..1 per cell.
-- opts.transforms: list of {weight, affine = {a, b, c, d, e, f},
--   variations = {linear = 1, swirl = 0.5, ...}, color = 0..1,
--   post = {a, b, c, d, e, f}?, colorSpeed = 0.5}. The affine maps
--   (x, y) to (a x + b y + c, d x + e y + f).
-- Variations: linear, sinusoidal, spherical, swirl, horseshoe, polar,
--   handkerchief, heart, disc, spiral, hyperbolic, diamond, ex, julia, bent,
--   waves, fisheye, popcorn, exponential, power, cosine, rings, fan,
--   eyefish, bubble, cylinder, noise, blur, gaussian, tangent, square, cross.
-- opts.final: a transform applied before plotting only.
-- opts.symmetry: n-fold rotation, negative also mirrors (default 1).
-- opts.n, w, h, supersample, splat, bounds, seed as for attractor.
function M.flame(opts)
    return T.flame(opts, randomSeed())
end

-- A random flame opts table ({transforms, symmetry}) for gen.flame. Add n,
-- w, h before rendering. seed defaults to gen.rand, nTransforms to 3.
-- An explicit seed has --vary mixed in, so sweeps change it either way.
function M.randomFlame(s, nTransforms)
    if s == nil then s = randomSeed() else s = s + core.vary * 1000003 end
    return T.randomFlame(s, nTransforms or 3)
end

-- Add points into a Field in place and return it. points is a list of
-- {x, y} or {x, y, weight}. opts.x, y, w, h is the scene rect the field
-- covers (default its cells), opts.weight scales every point (default 1),
-- opts.splat is "bilinear" (default) or "nearest".
function M.splat(field, points, opts)
    return T.splat(field, points, opts)
end

return M
