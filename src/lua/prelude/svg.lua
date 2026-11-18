local import = ...
local canvas = import("canvas")
local core = import("core")

local M = {}

local usage = "gen.exportSvg(filename, {vectorOnly = true})"

-- Export the canvas to an SVG file that shows what the PNG shows. A
-- canvas holding something SVG cannot draw exactly, such as a post pass,
-- is an error and no file is written.
-- Options: vectorOnly = true leaves the post passes out and writes just
-- the shapes. Returns how many passes were left out.
function M.exportSvg(filename, opts)
    canvas.rejectCanvasArg("gen.exportSvg", filename, opts, usage)
    if type(filename) ~= "string" then error("gen.exportSvg: expected a file name", 2) end
    if opts ~= nil and type(opts) ~= "table" then error("gen.exportSvg: options must be a table", 2) end
    for k in pairs(opts or {}) do
        if k ~= "vectorOnly" then error("gen.exportSvg: unknown option '" .. tostring(k) .. "'", 2) end
    end
    local vectorOnly = opts ~= nil and opts.vectorOnly == true
    local left, err, kind = core.exportSvg(canvas.need("gen.exportSvg"), filename, vectorOnly)
    if left == nil then
        if kind == "pass" then
            err = err .. "\n  (use gen.exportPng, or " .. usage .. " to export just the shapes)"
        end
        error("gen.exportSvg: " .. err, 2)
    end
    return left
end

return M
