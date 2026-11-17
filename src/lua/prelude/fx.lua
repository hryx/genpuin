local import = ...
local geo = import("geo")
local algo = import("core").algo

local M = {}

local pathPoints = geo.pathPoints

local function reshape(pts, closed)
    if closed then return geo.polygon(pts) end
    return geo.polyline(pts)
end

-- Displace each point by a random amount in [-amount, amount).
function M.jitter(shape, amount)
    local pts, closed = pathPoints(shape)
    if not pts then return shape end
    return reshape(algo.jitter(pts, amount), closed)
end

-- Chaikin curve smoothing, iterations default 2.
function M.smooth(shape, iterations)
    local pts, closed = pathPoints(shape)
    if not pts or #pts < 3 then return shape end
    return reshape(algo.smooth(pts, closed, iterations or 2), closed)
end

-- Varying stroke width along a path. Returns a list of styled segments,
-- each {shape = polyline, width = number}. segments defaults to one per
-- edge of the path.
function M.taper(shape, startWidth, endWidth, segments)
    local pts = pathPoints(shape)
    if not pts or #pts < 2 then return {} end
    local rpts, widths = algo.taper(pts, startWidth, endWidth, segments or #pts - 1)
    local out = {}
    for i = 1, #widths do
        out[i] = {shape = geo.polyline({rpts[i], rpts[i + 1]}), width = widths[i]}
    end
    return out
end

-- Fill a shape's bounding box with dots, density per unit area
-- (default 0.05). Closed shapes keep only the dots inside them.
function M.stipple(shape, density)
    local pts, closed = pathPoints(shape)
    if not pts then return {} end
    return algo.stipple(pts, closed, density or 0.05)
end

-- Convert a path into dashed segments.
-- Returns a list of polylines representing dash-on segments.
function M.dash(shape, dashLen, gapLen)
    local pts = pathPoints(shape)
    if not pts or #pts < 2 then return {} end
    local dashes = algo.dash(pts, dashLen, gapLen)
    for i = 1, #dashes do dashes[i] = geo.polyline(dashes[i]) end
    return dashes
end

return M
