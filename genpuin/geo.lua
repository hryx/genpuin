local M = {}

function M.vec2(x, y)
    return {x, y}
end

function M.vec2Add(a, b)
    return {a[1] + b[1], a[2] + b[2]}
end

function M.vec2Sub(a, b)
    return {a[1] - b[1], a[2] - b[2]}
end

function M.vec2Scale(v, s)
    return {v[1] * s, v[2] * s}
end

function M.vec2Len(v)
    return math.sqrt(v[1]^2 + v[2]^2)
end

function M.vec2FromAngle(angle, len)
    len = len or 1
    return {math.cos(angle) * len, math.sin(angle) * len}
end

function M.vec2Dot(a, b)
    return a[1] * b[1] + a[2] * b[2]
end

function M.vec2Lerp(a, b, t)
    return {a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t}
end

function M.vec2Rotate(v, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return {v[1] * c - v[2] * s, v[1] * s + v[2] * c}
end

function M.line(a, b)
    return {type = "line", a = a, b = b}
end

function M.polyline(points)
    return {type = "polyline", points = points}
end

function M.polygon(points)
    return {type = "polygon", points = points}
end

function M.circle(center, r)
    return {type = "circle", center = center, r = r}
end

function M.arc(center, r, startAngle, endAngle)
    return {type = "arc", center = center, r = r,
            startAngle = startAngle, endAngle = endAngle}
end

function M.rect(x, y, w, h, rx, ry)
    return {type = "rect", x = x, y = y, w = w, h = h, rx = rx, ry = ry or rx}
end

function M.ellipse(center, rx, ry)
    return {type = "ellipse", center = center, rx = rx, ry = ry}
end

function M.bezier(p0, p1, p2, p3)
    return {type = "bezier", p0 = p0, p1 = p1, p2 = p2, p3 = p3}
end

function M.spline(points)
    return {type = "spline", points = points}
end

function M.compound(contours)
    return {type = "compound", contours = contours}
end

-- Convert Catmull-Rom segment (p0,p1,p2,p3) to cubic bezier control points.
-- The curve is drawn between p1 and p2; p0 and p3 are context points.
-- Uses tau=0.5 (standard Catmull-Rom).
function M.catmullRomToBezier(p0, p1, p2, p3)
    return {
        {p1[1], p1[2]},
        {p1[1] + (p2[1] - p0[1]) / 6, p1[2] + (p2[2] - p0[2]) / 6},
        {p2[1] - (p3[1] - p1[1]) / 6, p2[2] - (p3[2] - p1[2]) / 6},
        {p2[1], p2[2]},
    }
end

-- Convert a spline's points into a list of cubic bezier segments.
-- Each segment is {b0, b1, b2, b3}.
-- First/last points are duplicated as phantom control points.
function M.splineToBeziers(points)
    if #points < 2 then return {} end
    local pts = {}
    -- Duplicate first and last as phantom control points
    pts[1] = points[1]
    for i = 1, #points do pts[i + 1] = points[i] end
    pts[#pts + 1] = points[#points]
    local segments = {}
    for i = 1, #pts - 3 do
        segments[#segments + 1] = M.catmullRomToBezier(pts[i], pts[i+1], pts[i+2], pts[i+3])
    end
    return segments
end

function M.bezierPoint(p0, p1, p2, p3, t)
    local u = 1 - t
    return {
        u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1],
        u*u*u*p0[2] + 3*u*u*t*p1[2] + 3*u*t*t*p2[2] + t*t*t*p3[2],
    }
end

function M.bezierTangent(p0, p1, p2, p3, t)
    local u = 1 - t
    return {
        3*u*u*(p1[1]-p0[1]) + 6*u*t*(p2[1]-p1[1]) + 3*t*t*(p3[1]-p2[1]),
        3*u*u*(p1[2]-p0[2]) + 6*u*t*(p2[2]-p1[2]) + 3*t*t*(p3[2]-p2[2]),
    }
end

-- Extract points from any point-based shape, returns nil for circles/arcs
local function getPoints(shape)
    if shape.type == "polyline" or shape.type == "polygon" then
        return shape.points
    elseif shape.type == "line" then
        return {shape.a, shape.b}
    end
    return nil
end

-- Compute cumulative segment lengths along a point list
local function cumLengths(pts)
    local lengths = {0}
    local total = 0
    for i = 2, #pts do
        local dx = pts[i][1] - pts[i-1][1]
        local dy = pts[i][2] - pts[i-1][2]
        total = total + math.sqrt(dx * dx + dy * dy)
        lengths[i] = total
    end
    return lengths, total
end

-- Interpolate along a point list at distance d from start
local function pointAtDist(pts, lengths, d)
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

-- Sample n evenly-spaced points along a path
function M.sampleAlong(shape, n)
    local pts = getPoints(shape)
    if not pts or #pts < 2 then return shape end
    local lengths, total = cumLengths(pts)
    local out = {}
    for i = 0, n - 1 do
        local d = (i / (n - 1)) * total
        table.insert(out, pointAtDist(pts, lengths, d))
    end
    return M.polyline(out)
end

-- Subdivide: insert midpoints between each pair (Chaikin-style prep)
function M.subdivide(shape, iterations)
    iterations = iterations or 1
    local pts = getPoints(shape)
    if not pts or #pts < 2 then return shape end
    local closed = shape.type == "polygon"
    for iter = 1, iterations do
        local out = {}
        local count = closed and #pts or #pts - 1
        for i = 1, count do
            local a = pts[i]
            local b = pts[(i % #pts) + 1]
            table.insert(out, a)
            table.insert(out, {(a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5})
        end
        if not closed then table.insert(out, pts[#pts]) end
        pts = out
    end
    if closed then return M.polygon(pts) end
    return M.polyline(pts)
end

-- Resample: redistribute n points evenly along the path
function M.resample(shape, n)
    return M.sampleAlong(shape, n)
end

return M
