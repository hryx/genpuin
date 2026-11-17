local geo = require("genpuin.geo")
local algo = require("genpuin.core").algo

local M = {}

-- Test if a point is inside a rectangle.
function M.pointInRect(point, x, y, w, h)
    local px, py = point[1], point[2]
    return px >= x and px <= x + w and py >= y and py <= y + h
end

-- Test if a point is inside a circle.
function M.pointInCircle(point, center, r)
    local dx, dy = point[1] - center[1], point[2] - center[2]
    return dx * dx + dy * dy <= r * r
end

-- Test if a point is inside a polygon (ray casting).
-- polygon is a polygon shape or a list of points.
function M.pointInPolygon(point, polygon)
    local pts = polygon
    if polygon.type == "polygon" then pts = polygon.points end
    return algo.pointInPolygon(point, pts)
end

-- Find the nearest point to a query point. Returns {point, index, dist},
-- or nil for an empty list.
function M.nearest(query, points)
    local index, dist = algo.nearest(query, points)
    if not index then return nil end
    return {point = points[index], index = index, dist = dist}
end

-- Find all points within a radius of the query, sorted by distance.
-- Returns a list of {point, index, dist}. Equal distances keep list order.
function M.withinRadius(query, points, radius)
    local index, dist = algo.withinRadius(query, points, radius)
    local results = {}
    for k = 1, #index do
        results[k] = {point = points[index[k]], index = index[k], dist = dist[k]}
    end
    return results
end

-- Push overlapping circles apart iteratively. Moves the circles' centers
-- in place and returns the list.
-- opts:
--   iterations: max steps (default 50)
--   padding: extra space between circles (default 0)
--   strength: push force multiplier (default 0.5)
--   bounds: {x, y, w, h} to constrain circles within
function M.separate(circles, opts)
    opts = opts or {}
    algo.separate(circles, opts.iterations or 50, opts.padding or 0,
        opts.strength or 0.5, opts.bounds)
    return circles
end

-- Place non-overlapping circles inside bounds.
-- opts:
--   bounds: {x, y, w, h} (required)
--   count: number of circles to place (required)
--   radius: fixed radius, or use minRadius/maxRadius for random sizes
--   padding: extra space between circles (default 0)
--   maxAttempts: placement tries per circle (default 500)
--   separation: post-placement separation iterations (default 50)
function M.packCircles(opts)
    local centers, radii = algo.packCircles(opts.bounds, opts.count, opts.radius,
        opts.minRadius, opts.maxRadius, opts.padding or 0, opts.maxAttempts or 500,
        opts.separation or 50)
    local circles = {}
    for k = 1, #centers do
        circles[k] = geo.circle(centers[k], radii[k])
    end
    return circles
end

return M
