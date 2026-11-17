local import = ...
local core = import("core")
local rand = import("rand")
local canvas = import("canvas")
local strict = import("strict")

local M = {}

-- Create a scalar field: a w x h grid of numbers, all set to value (default 0).
-- Methods: f:get(x, y), f:set(x, y, v), f:add(x, y, v) with zero-based cells,
-- f:sample(x, y) bilinear in cell units, f:size(), f:minMax(), f:normalize(),
-- f:clone(), f:fill(fn(x, y)), f:map(fn(v, x, y)), f:combine(op, other, t)
-- where op is "add", "sub", "mul", "min", "max" or "mix".
function M.field(w, h, value)
    return core.field.new(w, h, value)
end

-- Make a drawable shape from a field, stretched over the rect x, y, w, h.
-- opts.palette is a list of colors or of {offset, color} stops (default black to white).
-- opts.range = {lo, hi} maps field values onto the palette (default: the field's min and max).
-- opts.tone = "log" compresses highlights (opts.toneK sets strength), or a number for gamma.
-- opts.smooth = false samples nearest cell instead of bilinear.
-- Draw style keys that apply: opacity, blendMode.
function M.image(field, x, y, w, h, opts)
    opts = opts or {}
    return {
        type = "field", field = field, x = x, y = y, w = w, h = h,
        palette = opts.palette or {{0, 0, 0}, {1, 1, 1}},
        range = opts.range, tone = opts.tone, toneK = opts.toneK,
        smooth = opts.smooth,
    }
end

-- Post passes: gen.post.name(opts) adds a raster pass at this point in
-- the draw order. It rewrites the pixels drawn so far, and later draws
-- land on top. Passes need pixels, so SVG output skips them.
-- Every pass takes region = {x, y, w, h} to run on that rectangle only.
-- Distances are scene units, so a script looks the same at any -s.
-- Fields given as options are stretched over the whole image, regions or
-- not. Passes that use randomness take seed, filled from gen.rand when
-- absent. The options are checked at the call, so mistakes fail there.
local post = {}

local function addPass(name, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.seed == nil then o.seed = rand.randInt(1, 2147483646) end
    local ok, err = core.post.check(name, o)
    if not ok then error("gen.post." .. name .. ": " .. err, 3) end
    canvas.addPass(name, o)
end

-- Invert every channel.
function post.invert(opts) addPass("invert", opts) end

-- Sort runs of pixels along lines.
--   direction = "x" (rows, default) or "y" (columns).
--   angle = degrees, overrides direction (0 runs left to right, 90 top
--     to bottom, 180 right to left).
--   key = "luma" | "hue" | "sat" | "r" | "g" | "b" picks pixels into runs
--     where lo <= key <= hi (defaults 0.25, 0.8). With lo > hi it picks
--     values outside the window instead.
--   sortBy = key to order runs by (default: same as key).
--   mask = Field, replaces the key window: pixels where the mask is at
--     least maskThreshold (default 0.5) join runs.
--   reverse = true sorts high to low.
--   minLength, maxLength in scene units (maxLength 0 means no limit).
--   jitter = 0..1 shortens each run's maxLength by a random fraction.
--   chance = probability a run is sorted (default 1). seed.
--   passes = n sorts each run only partway: a pixel moves at most n
--     places, so a small n gives a half-melted look that grows with n.
--     Without it runs are fully sorted.
--   passesField = Field, scales passes per run by the field's mean over
--     the run (0 to 1), so melt strength can vary across the image.
function post.pixelSort(opts) addPass("pixelSort", opts) end

-- Offset each channel.
--   r, g, b = {dx, dy} in scene units (default {0, 0}).
--   wrap = true wraps around the edges instead of clamping.
function post.channelShift(opts) addPass("channelShift", opts) end

-- Move pixels, sampling bilinearly.
--   fieldX, fieldY = Fields. A value v moves by (v - 0.5) * 2 * amount,
--     so a 0..1 field moves by up to amount either way.
--   amount in scene units (default 10).
--   ampX, periodX: rows slide along x by ampX * sin(2 pi y / periodX + phase).
--   ampY, periodY: columns slide along y the same way. Scene units,
--     periods default 100. phase in radians.
function post.displace(opts) addPass("displace", opts) end

-- Cut the image into bands and slide some of them sideways.
--   axis = "x" (bands of rows move along x, default) or "y".
--   minHeight, maxHeight = band thickness in scene units (2, 30).
--   minShift, maxShift = shift size in scene units (5, 80), random sign.
--   chance = probability a band moves (0.3).
--   wrap = false clamps to the edge instead of wrapping. seed.
function post.tear(opts) addPass("tear", opts) end

-- Datamosh blocks.
--   count = number of blocks (40).
--   minSize, maxSize = block sides in scene units (10, 80).
--   grid = snap blocks to this grid in scene units, like codec
--     macroblocks (0 is off).
--   mode = "copy" (from a random place), "smearX" (left column streaked
--     across), "smearY" (top row streaked down) or "mixed" (default). seed.
function post.blockRepeat(opts) addPass("blockRepeat", opts) end

-- Quantize with a dither pattern.
--   levels = steps per channel (2), or palette = list of colors to snap
--     to (nearest in RGB).
--   method = "bayer" (ordered, default), "floyd" (Floyd-Steinberg error
--     diffusion), "blue" (tiled 64x64 void-and-cluster blue noise) or "none".
--   matrix = Bayer size 2, 4, 8 or 16 (4).
--   cell = dot size in scene units (0 is one pixel).
--   spread = threshold strength (default one quantization step).
function post.dither(opts) addPass("dither", opts) end

-- Quantize without dithering. The same options as dither, with method
-- "none" by default.
function post.posterize(opts) addPass("posterize", opts) end

-- Gaussian blur. radius = standard deviation in scene units (4).
function post.blur(opts) addPass("blur", opts) end

-- Glow around bright pixels.
--   threshold = luma where glow starts (0.7). radius in scene units (20).
--   strength = how much glow is added back (1).
function post.bloom(opts) addPass("bloom", opts) end

-- Film grain.
--   amount = peak noise per channel (0.1).
--   mono = false gives each channel its own noise.
--   size = grain size in scene units (1). seed.
function post.grain(opts) addPass("grain", opts) end

-- Remap black and white points, then gamma.
--   black (0), white (1), gamma (1, above 1 brightens midtones),
--   outBlack (0), outWhite (1).
function post.levels(opts) addPass("levels", opts) end

-- Darken bands.
--   period = line spacing in scene units (4). width = dark band width in
--   scene units (2). strength = 0..1 darkening (0.5).
--   axis = "x" (horizontal lines, default) or "y" (vertical).
function post.scanlines(opts) addPass("scanlines", opts) end

M.post = strict.api(post, "gen.post")
getmetatable(post).__call = function()
    error("gen.post is a table of passes. Call gen.post.name(opts), for example gen.post.blur({radius = 2})", 2)
end

-- Export the canvas to a PNG file. opts: scale, ss (supersample), depth (8 or 16).
function M.exportPng(filename, opts)
    canvas.rejectCanvasArg("gen.exportPng", filename, opts, "gen.exportPng(filename, opts)")
    core.export(canvas.need("gen.exportPng"), filename, opts)
end

-- Export the canvas to a PPM (P6 binary) image file.
function M.exportPpm(filename, scale)
    canvas.rejectCanvasArg("gen.exportPpm", filename, scale, "gen.exportPpm(filename, scale)")
    core.export(canvas.need("gen.exportPpm"), filename, {scale = scale})
end

return M
