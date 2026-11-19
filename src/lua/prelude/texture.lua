-- Flow tracing, density renders and Field filters backed by core.texture.
-- The noise samplers live in noise.lua. Functions here return Fields to
-- draw with gen.image.

local import = ...
local core = import("core")
local rand = import("rand")
local strict = import("strict")

local T = core.texture

local M = {}

local function randomSeed()
    return rand.randInt(1, 2147483646)
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

local snapKeys = {
    cell = true, mode = true, amount = true, jitter = true, chance = true,
    angle = true, center = true, spokes = true, feedback = true,
}
local splatSnapKeys = {
    cell = true, mode = true, amount = true, jitter = true, chance = true,
    angle = true, center = true, spokes = true,
}

-- Raise a bad opts.snap at the line that called the gen function. The
-- caller has checked the keys with strict.options, which raises at that
-- line only when called from the gen function itself.
local function checkSnap(what, opts, use)
    local ok, err = T.checkSnap(opts, use)
    if not ok then error(what .. ": " .. err, 3) end
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
-- opts.snap quantizes the plotted points for a gritty look. A number is
--   the cell size, or a table:
--   cell: lattice spacing in output cells (required, above 0).
--   mode: "grid" (default), "rows" (y only, scan lines), "columns" (x
--     only), "hex", or "polar" (angle in steps of 360 / spokes degrees
--     around center, radius in steps of cell).
--   amount: 0..1, how far a point moves toward its lattice point
--     (default 1). Below 1 the true image shows through.
--   jitter: random offset after snapping, uniform in a disc whose radius
--     is this fraction of cell (default 0).
--   chance: 0..1, the share of points snapped at all (default 1).
--   angle: lattice rotation in degrees (default 0). Turns polar spokes.
--   center = {x, y}: polar center in output cells (default the middle).
--   spokes: polar angle steps (default 24).
--   feedback: true iterates the map on the snapped point, not only plots
--     it there (default false). Attractors then fall into short cycles
--     and show a handful of dots unless jitter keeps them moving.
--   Jitter and chance draw from their own stream of opts.seed, so the
--   orbit is the same as without snap.
function M.attractor(opts)
    if type(opts) == "table" and opts.snap ~= nil then
        if type(opts.snap) == "table" then strict.options("gen.attractor snap", opts.snap, snapKeys) end
        checkSnap("gen.attractor", opts, "orbit")
    end
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
-- opts.snap quantizes the plotted points, with the keys listed for
--   gen.attractor. With feedback the chaos game runs on the lattice and
--   opts.final, if any, bends the lattice before plotting.
function M.flame(opts)
    if type(opts) == "table" and opts.snap ~= nil then
        if type(opts.snap) == "table" then strict.options("gen.flame snap", opts.snap, snapKeys) end
        checkSnap("gen.flame", opts, "orbit")
    end
    return T.flame(opts, randomSeed())
end

-- A random flame opts table ({transforms, symmetry}) for gen.flame. Add n,
-- w, h before rendering. seed defaults to gen.rand, nTransforms to 3.
function M.randomFlame(s, nTransforms)
    if s == nil then s = randomSeed() end
    return T.randomFlame(s, nTransforms or 3)
end

-- Add points into a Field in place and return it. points is a list of
-- {x, y} or {x, y, weight}. opts.x, y, w, h is the scene rect the field
-- covers (default its cells), opts.weight scales every point (default 1),
-- opts.splat is "bilinear" (default) or "nearest".
-- opts.snap quantizes the points as for gen.attractor, in cells of the
-- field and without feedback. opts.seed seeds its jitter and chance
-- (default from gen.rand).
function M.splat(field, points, opts)
    if type(opts) == "table" and opts.snap ~= nil then
        if type(opts.snap) == "table" then strict.options("gen.splat snap", opts.snap, splatSnapKeys) end
        checkSnap("gen.splat", opts, "splat")
        return T.splat(field, points, opts, randomSeed())
    end
    return T.splat(field, points, opts)
end

return M
