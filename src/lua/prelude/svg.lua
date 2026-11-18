local import = ...
local canvas = import("canvas")
local core = import("core")
local strict = import("strict")

local M = {}

local usage = "gen.exportSvg(filename, {vectorOnly = true})"

-- Export the canvas to an SVG file that shows what the PNG shows. A
-- canvas holding something SVG cannot draw exactly, such as a post pass,
-- is an error and no file is written.
-- Options:
--   vectorOnly = true leaves the post passes out and writes just the
--   shapes.
--   width = display width in pixels, a whole number from 1 to 32768,
--   with the height following as gen.exportPng rounds it. The viewBox
--   stays the canvas size, so this only sets the size a viewer shows.
--   Default: the canvas size.
-- Returns how many passes were left out.
function M.exportSvg(filename, opts)
    canvas.rejectCanvasArg("gen.exportSvg", filename, opts, usage)
    if type(filename) ~= "string" then error("gen.exportSvg: expected a file name", 2) end
    strict.options("gen.exportSvg", opts, {vectorOnly = true, width = true})
    local left, err, kind = core.exportSvg(canvas.need("gen.exportSvg"), filename, opts)
    if left == nil then
        if kind == "pass" then
            err = err .. "\n  (use gen.exportPng, or " .. usage .. " to export just the shapes)"
        end
        error("gen.exportSvg: " .. err, 2)
    end
    return left
end

return M
