local M = {}

local function xformShape(shape, fn)
    local s = {}
    for k, v in pairs(shape) do s[k] = v end

    if shape.type == "ellipse" then
        s.center = fn(shape.center)

    elseif shape.type == "circle" then
        s.center = fn(shape.center)

    elseif shape.type == "line" then
        s.a = fn(shape.a)
        s.b = fn(shape.b)

    elseif shape.type == "polyline" or shape.type == "polygon" or shape.type == "spline" then
        local pts = {}
        for i, pt in ipairs(shape.points) do
            pts[i] = fn(pt)
        end
        s.points = pts

    elseif shape.type == "rect" then
        local corner = fn({shape.x, shape.y})
        s.x, s.y = corner[1], corner[2]

    elseif shape.type == "bezier" then
        s.p0 = fn(shape.p0)
        s.p1 = fn(shape.p1)
        s.p2 = fn(shape.p2)
        s.p3 = fn(shape.p3)

    elseif shape.type == "arc" then
        s.center = fn(shape.center)
    end

    return s
end

-- Translate a shape by (dx, dy).
function M.translate(shape, dx, dy)
    return xformShape(shape, function(pt)
        return {pt[1] + dx, pt[2] + dy}
    end)
end

-- Rotate a shape around the origin by the given angle in radians.
function M.rotate(shape, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return xformShape(shape, function(pt)
        return {pt[1] * c - pt[2] * s, pt[1] * s + pt[2] * c}
    end)
end

-- Rotate a shape around a pivot point by the given angle in radians.
function M.rotateAround(shape, angle, pivot)
    local c, s = math.cos(angle), math.sin(angle)
    local px, py = pivot[1], pivot[2]
    return xformShape(shape, function(pt)
        local dx, dy = pt[1] - px, pt[2] - py
        return {px + dx * c - dy * s, py + dx * s + dy * c}
    end)
end

-- Scale a shape from the origin. If sy is omitted, scales uniformly.
function M.scale(shape, sx, sy)
    sy = sy or sx
    return xformShape(shape, function(pt)
        return {pt[1] * sx, pt[2] * sy}
    end)
end

-- Scale a shape around a pivot point.
function M.scaleAround(shape, sx, sy, pivot)
    local px, py = pivot[1], pivot[2]
    return xformShape(shape, function(pt)
        return {px + (pt[1] - px) * sx, py + (pt[2] - py) * sy}
    end)
end

-- Reflect a shape across the Y axis (negate x).
function M.reflectX(shape)
    return xformShape(shape, function(pt)
        return {-pt[1], pt[2]}
    end)
end

-- Reflect a shape across the X axis (negate y).
function M.reflectY(shape)
    return xformShape(shape, function(pt)
        return {pt[1], -pt[2]}
    end)
end

-- Reflect a shape across an arbitrary axis through center at the given angle.
function M.reflect(shape, center, angle)
    local px, py = center[1], center[2]
    local c2 = math.cos(2 * angle)
    local s2 = math.sin(2 * angle)
    return xformShape(shape, function(pt)
        local dx, dy = pt[1] - px, pt[2] - py
        return {px + dx * c2 + dy * s2, py + dx * s2 - dy * c2}
    end)
end

return M
