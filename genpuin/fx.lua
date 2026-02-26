local geo = require("genpuin.geo")
local rand = require("genpuin.rand")

local M = {}

-- Extract points from a shape
local function getPoints(shape)
    if shape.type == "polyline" or shape.type == "polygon" then
        return shape.points, shape.type == "polygon"
    elseif shape.type == "line" then
        return {shape.a, shape.b}, false
    end
    return nil, false
end

-- Displace each point by a random amount
function M.jitter(shape, amount)
    local pts, closed = getPoints(shape)
    if not pts then return shape end
    local out = {}
    for i, pt in ipairs(pts) do
        table.insert(out, {
            pt[1] + rand.randRange(-amount, amount),
            pt[2] + rand.randRange(-amount, amount),
        })
    end
    if closed then return geo.polygon(out) end
    return geo.polyline(out)
end

-- Chaikin curve smoothing
function M.smooth(shape, iterations)
    iterations = iterations or 2
    local pts, closed = getPoints(shape)
    if not pts or #pts < 3 then return shape end
    for iter = 1, iterations do
        local out = {}
        local count = closed and #pts or #pts - 1
        for i = 1, count do
            local a = pts[i]
            local b = pts[(i % #pts) + 1]
            table.insert(out, {a[1] * 0.75 + b[1] * 0.25, a[2] * 0.75 + b[2] * 0.25})
            table.insert(out, {a[1] * 0.25 + b[1] * 0.75, a[2] * 0.25 + b[2] * 0.75})
        end
        if not closed then
            -- preserve endpoints
            out[1] = pts[1]
            out[#out] = pts[#pts]
        end
        pts = out
    end
    if closed then return geo.polygon(pts) end
    return geo.polyline(pts)
end

-- Varying stroke width along a path — returns a list of styled segments
-- Each segment is {shape = polyline, width = number}
function M.taper(shape, startWidth, endWidth, segments)
    local pts, _ = getPoints(shape)
    if not pts or #pts < 2 then return {} end
    segments = segments or #pts - 1
    local resampled = geo.sampleAlong(shape, segments + 1)
    local rpts = resampled.points
    local out = {}
    for i = 1, #rpts - 1 do
        local t = (i - 1) / (#rpts - 2)
        local w = startWidth + (endWidth - startWidth) * t
        table.insert(out, {
            shape = geo.polyline({rpts[i], rpts[i + 1]}),
            width = w,
        })
    end
    return out
end

-- Fill a shape's bounding box with dots
function M.stipple(shape, density)
    density = density or 0.05
    local pts, closed = getPoints(shape)
    if not pts then return {} end
    -- compute bounding box
    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge
    for _, pt in ipairs(pts) do
        if pt[1] < minX then minX = pt[1] end
        if pt[2] < minY then minY = pt[2] end
        if pt[1] > maxX then maxX = pt[1] end
        if pt[2] > maxY then maxY = pt[2] end
    end
    -- point-in-polygon (ray casting) for closed shapes
    local function inside(px, py)
        if not closed then return true end
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
    local dots = {}
    local w, h = maxX - minX, maxY - minY
    local count = math.floor(w * h * density)
    for i = 1, count do
        local px = minX + rand.rand() * w
        local py = minY + rand.rand() * h
        if inside(px, py) then
            table.insert(dots, {px, py})
        end
    end
    return dots
end

-- Convert a path into dashed segments.
-- Returns a list of polylines representing dash-on segments.
function M.dash(shape, dashLen, gapLen)
    local pts, _ = getPoints(shape)
    if not pts or #pts < 2 then return {} end

    -- Build cumulative lengths
    local lengths = {0}
    local total = 0
    for i = 2, #pts do
        local dx = pts[i][1] - pts[i-1][1]
        local dy = pts[i][2] - pts[i-1][2]
        total = total + math.sqrt(dx * dx + dy * dy)
        lengths[i] = total
    end

    -- Interpolate a point at distance d along the path
    local function pointAt(d)
        for i = 2, #pts do
            if d <= lengths[i] then
                local segLen = lengths[i] - lengths[i-1]
                if segLen == 0 then return {pts[i][1], pts[i][2]} end
                local t = (d - lengths[i-1]) / segLen
                return {
                    pts[i-1][1] + (pts[i][1] - pts[i-1][1]) * t,
                    pts[i-1][2] + (pts[i][2] - pts[i-1][2]) * t,
                }
            end
        end
        return {pts[#pts][1], pts[#pts][2]}
    end

    local cycle = dashLen + gapLen
    local segments = {}
    local d = 0
    while d < total do
        local dashEnd = math.min(d + dashLen, total)
        -- Sample points along this dash segment
        local seg = {pointAt(d)}
        -- Include any original vertices that fall within the dash
        for i = 2, #pts do
            if lengths[i] > d and lengths[i] < dashEnd then
                seg[#seg + 1] = {pts[i][1], pts[i][2]}
            end
        end
        seg[#seg + 1] = pointAt(dashEnd)
        if #seg >= 2 then
            segments[#segments + 1] = geo.polyline(seg)
        end
        d = d + cycle
    end
    return segments
end

return M
