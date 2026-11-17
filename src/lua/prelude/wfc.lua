local import = ...
local core = import("core")
local rand = import("rand")
local canvas = import("canvas")

local M = {}

local function withSeed(opts)
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    if o.seed == nil then o.seed = rand.randInt(1, 2147483646) end
    return o
end

-- Wave function collapse, simple tiled model (after Maxim Gumin,
-- github.com/mxgmn/WaveFunctionCollapse). Returns result[y][x] =
-- {tile = name or index, rot = 0..3, flip = bool}, 1-based. A variant is
-- the tile mirrored left to right when flip is set, then turned rot
-- quarter turns clockwise.
-- opts:
--   w, h         grid size in cells
--   tiles        list of {name, edges = {n, e, s, w}, weight = 1,
--                symmetry = "X" | "I" | "L" | "T" | "/" | "F"}
--                symmetry picks which rotations and reflections exist
--   seed         defaults to one drawn from gen.rand
--   wrap         periodic output, edges meet across the border
--   retries      restarts after a contradiction, default 10
--   constraints  list of {x, y, tile, rot, flip} pre-collapsed cells,
--                tile by name or index, rot and flip optional
--   weightMap    {[name or index] = Field} multiplies a tile's weight per
--                cell, the Field stretched over the grid. Zero forbids it.
-- Edge sockets are strings read clockwise around the tile, and touching
-- edges fit when one reads as the other reversed. So "a" and "aba" fit
-- themselves while "ab" needs "ba". Numbers fit only the same number.
-- Also returns the number of attempts used. Raises an error when every
-- attempt hits a contradiction.
function M.wfc(opts)
    return core.wfc.tiled(withSeed(opts))
end

-- Wave function collapse, overlapping model. Grows a grid of integers
-- whose every n by n window appears in the sample. Returns out[y][x].
-- opts:
--   sample          sample[y][x] grid of integers (palette indices)
--   n               pattern size, default 3
--   w, h            output size in cells
--   seed            defaults to one drawn from gen.rand
--   periodicInput   sample wraps around, default true
--   periodicOutput  output wraps around, default true
--   symmetry        1 to 8 rotations and reflections of each window, default 8
--   ground          pin the sample's bottom-left window to the bottom rows
--   retries         restarts after a contradiction, default 10
function M.wfcOverlap(opts)
    return core.wfc.overlap(withSeed(opts))
end

-- Walk a gen.wfc result and return a list of placements
-- {tile, x, y, size, rot, flip} where x, y is the cell center in pixels.
-- opts: size (cell size in pixels, default 10), x, y (top-left origin,
-- default 0), draw (optional function(tile, x, y, size, rot, flip)
-- called per cell, if it returns a shape and a style they go onto c).
function M.wfcDraw(c, result, opts)
    opts = opts or {}
    local size = opts.size or 10
    local ox, oy = opts.x or 0, opts.y or 0
    local draw = opts.draw
    local out = {}
    for row = 1, #result do
        local cells = result[row]
        for col = 1, #cells do
            local cell = cells[col]
            local x = ox + (col - 0.5) * size
            local y = oy + (row - 0.5) * size
            out[#out + 1] = {tile = cell.tile, x = x, y = y, size = size, rot = cell.rot, flip = cell.flip}
            if draw then
                local shape, style = draw(cell.tile, x, y, size, cell.rot, cell.flip)
                if shape and c then
                    canvas.draw(c, shape, style)
                end
            end
        end
    end
    return out
end

return M
