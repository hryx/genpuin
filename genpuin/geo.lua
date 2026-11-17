local algo = require("genpuin.core").algo

local M = {}

-- Create a 2D vector.
function M.vec2(x, y)
    return {x, y}
end

-- Add two vectors.
function M.vec2Add(a, b)
    return {a[1] + b[1], a[2] + b[2]}
end

-- Subtract vector b from a.
function M.vec2Sub(a, b)
    return {a[1] - b[1], a[2] - b[2]}
end

-- Scale a vector by a scalar.
function M.vec2Scale(v, s)
    return {v[1] * s, v[2] * s}
end

-- Length of a vector.
function M.vec2Len(v)
    return math.sqrt(v[1]^2 + v[2]^2)
end

-- Create a unit vector from an angle, optionally scaled by len.
function M.vec2FromAngle(angle, len)
    len = len or 1
    return {math.cos(angle) * len, math.sin(angle) * len}
end

-- Dot product of two vectors.
function M.vec2Dot(a, b)
    return a[1] * b[1] + a[2] * b[2]
end

-- Linearly interpolate between two vectors by t.
function M.vec2Lerp(a, b, t)
    return {a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t}
end

-- Rotate a vector by an angle in radians.
function M.vec2Rotate(v, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return {v[1] * c - v[2] * s, v[1] * s + v[2] * c}
end

-- Create a line shape from two points.
function M.line(a, b)
    return {type = "line", a = a, b = b}
end

-- Create an open polyline shape from a list of points.
function M.polyline(points)
    return {type = "polyline", points = points}
end

-- Create a closed polygon shape from a list of points.
function M.polygon(points)
    return {type = "polygon", points = points}
end

-- Create a circle shape.
function M.circle(center, r)
    return {type = "circle", center = center, r = r}
end

-- Create an arc shape from startAngle to endAngle (radians).
function M.arc(center, r, startAngle, endAngle)
    return {type = "arc", center = center, r = r,
            startAngle = startAngle, endAngle = endAngle}
end

-- Create a rectangle shape, optionally with rounded corners (rx, ry).
function M.rect(x, y, w, h, rx, ry)
    return {type = "rect", x = x, y = y, w = w, h = h, rx = rx, ry = ry or rx}
end

-- Create an ellipse shape.
function M.ellipse(center, rx, ry)
    return {type = "ellipse", center = center, rx = rx, ry = ry}
end

-- Create a cubic bezier shape from four control points.
function M.bezier(p0, p1, p2, p3)
    return {type = "bezier", p0 = p0, p1 = p1, p2 = p2, p3 = p3}
end

-- Create a Catmull-Rom spline through the given points.
function M.spline(points)
    return {type = "spline", points = points}
end

-- Create a compound shape from multiple polygon contours.
function M.compound(contours)
    return {type = "compound", contours = contours}
end

-- Convert Catmull-Rom segment (p0,p1,p2,p3) to cubic bezier control points.
-- The curve is drawn between p1 and p2. p0 and p3 are context points.
-- Uses tau=0.5 (standard Catmull-Rom).
M.catmullRomToBezier = algo.catmullRomToBezier

-- Convert a spline's points into a list of cubic bezier segments.
-- Each segment is {b0, b1, b2, b3}.
-- First/last points are duplicated as phantom control points.
M.splineToBeziers = algo.splineToBeziers

-- Evaluate a cubic bezier at parameter t, returning the point.
M.bezierPoint = algo.bezierPoint

-- Tangent vector of a cubic bezier at parameter t.
M.bezierTangent = algo.bezierTangent

-- Points of a polyline, polygon or line, and whether the path is closed.
-- Nil for shapes without a point list.
function M.pathPoints(shape)
    if shape.type == "polyline" then
        return shape.points, false
    elseif shape.type == "polygon" then
        return shape.points, true
    elseif shape.type == "line" then
        return {shape.a, shape.b}, false
    end
    return nil, false
end

-- Sample n evenly-spaced points along a path, returning a polyline.
-- Shapes without at least two points are returned unchanged.
function M.sampleAlong(shape, n)
    local pts = M.pathPoints(shape)
    if not pts or #pts < 2 then return shape end
    return M.polyline(algo.sampleAlong(pts, n))
end

-- Subdivide a shape by inserting midpoints between each pair of points.
function M.subdivide(shape, iterations)
    local pts, closed = M.pathPoints(shape)
    if not pts or #pts < 2 then return shape end
    pts = algo.subdivide(pts, closed, iterations or 1)
    if closed then return M.polygon(pts) end
    return M.polyline(pts)
end

-- Redistribute n points evenly along a path (alias for sampleAlong).
function M.resample(shape, n)
    return M.sampleAlong(shape, n)
end

return M
