local import = ...
local geo = import("geo")
local core = import("core")
local algo = core.algo
local P = core.pathops

-- Path effects. Each takes any shape with an outline: polyline, polygon,
-- line, circle, ellipse, rect, arc, bezier, spline or compound. Curves are
-- flattened to points first, see geo.paths.

local M = {}

-- Displace each point by a random amount in [-amount, amount). Circles,
-- ellipses and rects come back as polygons, arcs, beziers and splines as
-- polylines, compounds as compounds.
function M.jitter(shape, amount)
    local paths, closed = geo.paths(shape, "jitter")
    if not paths then return shape end
    for i, pts in ipairs(paths) do paths[i] = algo.jitter(pts, amount) end
    return geo.fromPaths(shape, paths, closed)
end

-- Chaikin curve smoothing, iterations default 2. Shapes come back as in
-- gen.jitter. Paths with fewer than three points are left as they are.
function M.smooth(shape, iterations)
    local paths, closed = geo.paths(shape, "smooth")
    if not paths then return shape end
    if shape.type ~= "compound" and #paths[1] < 3 then return shape end
    for i, pts in ipairs(paths) do
        if #pts >= 3 then paths[i] = algo.smooth(pts, closed, iterations or 2) end
    end
    return geo.fromPaths(shape, paths, closed)
end

-- Varying stroke width along a path. Returns a list of styled segments,
-- each {shape = polyline, width = number}. segments defaults to one per
-- edge of the path. Takes every shape but a compound of several contours.
-- A polygon runs from its first point to its last without the closing
-- edge, while circles, ellipses, rects and one-contour compounds go all
-- the way round.
function M.taper(shape, startWidth, endWidth, segments)
    local paths = geo.paths(shape, "taper", true)
    if not paths then return {} end
    local pts = geo.onePath(paths, shape, "taper")
    if #pts < 2 then return {} end
    local rpts, widths = algo.taper(pts, startWidth, endWidth, segments or #pts - 1)
    local out = {}
    for i = 1, #widths do
        out[i] = {shape = geo.polyline({rpts[i], rpts[i + 1]}), width = widths[i]}
    end
    return out
end

-- Fill a shape with uniform random dots, density per unit area (default
-- 0.05). Dots are drawn over the shape's bounding box, x then y from the
-- gen.rand stream for each, and kept when inside the shape as it is
-- filled: the disc of a circle, a rounded rect without its corners, the
-- pie slice of an arc, a compound by the nonzero rule so its holes stay
-- empty, a polygon by the even-odd rule. Open shapes (polyline, line,
-- bezier, spline) keep every dot of their bounding box. Other shape
-- types raise an error.
function M.stipple(shape, density)
    local dots, err = P.stipple(shape, density or 0.05)
    if not dots then error("stipple: " .. err, 2) end
    return dots
end

-- Convert a path into dashed segments.
-- Returns a list of polylines representing dash-on segments. A polygon
-- runs from its first point to its last without the closing edge, while
-- circles, ellipses and rects go all the way round, and a compound is
-- dashed contour by contour.
function M.dash(shape, dashLen, gapLen)
    local paths = geo.paths(shape, "dash", true)
    if not paths then return {} end
    local out = {}
    for _, pts in ipairs(paths) do
        if #pts >= 2 then
            for _, d in ipairs(algo.dash(pts, dashLen, gapLen)) do out[#out + 1] = geo.polyline(d) end
        end
    end
    return out
end

return M
