local import = ...
local core = import("core")
local rand = import("rand")

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

-- Add a raster pass at this point in the draw order. It rewrites the pixels
-- drawn so far, and later draws land on top. Raster output only, SVG skips it.
-- Passes that use randomness take opts.seed, filled from gen.rand when absent.
-- The name and options are checked here, so mistakes fail at this call.
function M.post(c, name, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.seed == nil then o.seed = rand.randInt(1, 2147483646) end
    local ok, err = core.post.check(name, o)
    if not ok then error("gen.post: " .. err, 2) end
    table.insert(c.elements, {pass = name, opts = o, shape = {type = "pass"}, style = {}})
    return c
end

-- Export the canvas to a PNG file. opts: scale, ss (supersample), depth (8 or 16).
function M.exportPng(c, filename, opts)
    core.export(c, filename, opts)
end

-- Export the canvas to a PPM (P6 binary) image file.
function M.exportPpm(c, filename, scale)
    core.export(c, filename, {scale = scale})
end

return M
