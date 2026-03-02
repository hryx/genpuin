local geo = require("genpuin.geo")
local util = require("genpuin.util")
local rand = require("genpuin.rand")

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
function M.pointInPolygon(point, polygon)
    local pts = polygon
    if polygon.type == "polygon" then pts = polygon.points end
    local px, py = point[1], point[2]
    local n = #pts
    local hit = false
    local j = n
    for i = 1, n do
        local yi, yj = pts[i][2], pts[j][2]
        local xi, xj = pts[i][1], pts[j][1]
        if (yi > py) ~= (yj > py) then
            local xIntersect = xi + (py - yi) / (yj - yi) * (xj - xi)
            if px < xIntersect then hit = not hit end
        end
        j = i
    end
    return hit
end

-- Find the nearest point to a query point. Returns {point, index, dist}.
function M.nearest(query, points)
    if #points == 0 then return nil end
    local bestDist = math.huge
    local bestIdx = 1
    for i = 1, #points do
        local d = util.dist(query, points[i])
        if d < bestDist then
            bestDist = d
            bestIdx = i
        end
    end
    return {point = points[bestIdx], index = bestIdx, dist = bestDist}
end

-- Find all points within a radius of the query, sorted by distance.
function M.withinRadius(query, points, radius)
    local results = {}
    local r2 = radius * radius
    for i = 1, #points do
        local dx = points[i][1] - query[1]
        local dy = points[i][2] - query[2]
        local d2 = dx * dx + dy * dy
        if d2 <= r2 then
            results[#results + 1] = {point = points[i], index = i, dist = math.sqrt(d2)}
        end
    end
    table.sort(results, function(a, b) return a.dist < b.dist end)
    return results
end

-- Push overlapping circles apart iteratively.
-- opts:
--   iterations: max steps (default 50)
--   padding: extra space between circles (default 0)
--   strength: push force multiplier (default 0.5)
--   bounds: {x, y, w, h} to constrain circles within
function M.separate(circles, opts)
    opts = opts or {}
    local iterations = opts.iterations or 50
    local padding = opts.padding or 0
    local strength = opts.strength or 0.5
    local bounds = opts.bounds

    for _ = 1, iterations do
        local moved = false
        for i = 1, #circles do
            local ci = circles[i]
            local cx, cy = ci.center[1], ci.center[2]
            local ri = ci.r
            local dx, dy = 0, 0

            for j = 1, #circles do
                if i ~= j then
                    local cj = circles[j]
                    local ox, oy = cj.center[1], cj.center[2]
                    local distX, distY = cx - ox, cy - oy
                    local dist = math.sqrt(distX * distX + distY * distY)
                    local minDist = ri + cj.r + padding

                    if dist < minDist then
                        if dist < 1e-10 then
                            distX = rand.rand() - 0.5
                            distY = rand.rand() - 0.5
                            dist = math.sqrt(distX * distX + distY * distY)
                        end
                        local overlap = (minDist - dist) * 0.5 * strength
                        dx = dx + distX / dist * overlap
                        dy = dy + distY / dist * overlap
                        moved = true
                    end
                end
            end

            ci.center[1] = cx + dx
            ci.center[2] = cy + dy

            if bounds then
                local bx, by, bw, bh = bounds[1], bounds[2], bounds[3], bounds[4]
                ci.center[1] = math.max(bx + ri, math.min(bx + bw - ri, ci.center[1]))
                ci.center[2] = math.max(by + ri, math.min(by + bh - ri, ci.center[2]))
            end
        end

        if not moved then break end
    end

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
    local bounds = opts.bounds
    local count = opts.count
    local padding = opts.padding or 0
    local maxAttempts = opts.maxAttempts or 500
    local sepIters = opts.separation or 50

    local bx, by, bw, bh = bounds[1], bounds[2], bounds[3], bounds[4]
    local circles = {}

    for _ = 1, count do
        local r
        if opts.radius then
            r = opts.radius
        else
            r = rand.randRange(opts.minRadius, opts.maxRadius)
        end

        local bestPt, bestMinDist = nil, -1

        for _ = 1, maxAttempts do
            local px = bx + r + rand.rand() * math.max(0, bw - 2 * r)
            local py = by + r + rand.rand() * math.max(0, bh - 2 * r)

            local minDist = math.huge
            for j = 1, #circles do
                local other = circles[j]
                local d = util.dist({px, py}, other.center) - other.r - r - padding
                if d < minDist then minDist = d end
            end

            if minDist >= 0 and minDist > bestMinDist then
                bestPt = {px, py}
                bestMinDist = minDist
            end

            if bestMinDist >= 0 and _ >= 30 then break end
        end

        if bestPt then
            circles[#circles + 1] = geo.circle(bestPt, r)
        end
    end

    if sepIters > 0 and #circles > 0 then
        M.separate(circles, {iterations = sepIters, padding = padding, bounds = bounds})
    end

    return circles
end

return M
