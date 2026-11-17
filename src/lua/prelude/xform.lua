-- Affine transforms on shape tables. Each returns a new shape and leaves the
-- input alone.
--
-- Shapes the renderer only knows axis aligned (rect, ellipse, circle) keep
-- their type while the transform allows it, and otherwise become a polygon
-- flattened at about one point per unit of length. A transformed arc stays an
-- arc under rotation, uniform scale and reflection. A non-uniform scale would
-- make it elliptical, which neither the arc shape nor a polyline (it would lose
-- the pie fill) can stand in for, so that raises an error. A field image only
-- takes translation and positive axis scales, anything else raises an error.

local M = {}

local eps = 1e-9
local atan2 = math.atan2 or math.atan

local function near(a, b) return math.abs(a - b) < eps end

local function copy(shape)
    local s = {}
    for k, v in pairs(shape) do s[k] = v end
    return s
end

local function mapAll(pts, fn)
    local out = {}
    for i, pt in ipairs(pts) do out[i] = fn(pt) end
    return out
end

local function segmentsFor(len)
    return math.max(64, math.min(4096, math.ceil(len)))
end

local function ellipsePoints(c, rx, ry)
    local n = segmentsFor(2 * math.pi * math.max(rx, ry))
    local pts = {}
    for i = 0, n - 1 do
        local t = 2 * math.pi * i / n
        pts[#pts + 1] = {c[1] + rx * math.cos(t), c[2] + ry * math.sin(t)}
    end
    return pts
end

-- Corner order and arc parameterization follow the renderer's rounded rect.
local function rectPoints(shape)
    local x, y, w, h = shape.x, shape.y, shape.w, shape.h
    local rx0, ry0 = shape.rx or 0, shape.ry or 0
    if rx0 <= 0 and ry0 <= 0 then
        return {{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}}
    end
    local rx = math.min(rx0 > 0 and rx0 or ry0, w / 2)
    local ry = math.min(ry0 > 0 and ry0 or rx0, h / 2)
    local n = math.max(4, math.ceil(math.pi / 2 * math.max(rx, ry)))
    local corners = {
        {x + w - rx, y + ry, -math.pi / 2},
        {x + w - rx, y + h - ry, 0},
        {x + rx, y + h - ry, math.pi / 2},
        {x + rx, y + ry, math.pi},
    }
    local pts = {}
    for _, cn in ipairs(corners) do
        for i = 0, n do
            local t = cn[3] + math.pi / 2 * i / n
            pts[#pts + 1] = {cn[1] + rx * math.cos(t), cn[2] + ry * math.sin(t)}
        end
    end
    return pts
end

-- The linear part m = {a, b, c, d} maps (x, y) to (a x + b y, c x + d y).
-- Its classification decides which shape types survive.
local function axisKeeping(m) return near(m[2], 0) and near(m[3], 0) end
local function axisSwapping(m) return near(m[1], 0) and near(m[4], 0) end
local function rotationLike(m) return near(m[1], m[4]) and near(m[2], -m[3]) end
local function reflectionLike(m) return near(m[1], -m[4]) and near(m[2], m[3]) end

local function polygonOf(pts, fn)
    return {type = "polygon", points = mapAll(pts, fn)}
end

local function xformRect(shape, fn)
    local s = copy(shape)
    local p = fn({shape.x, shape.y})
    local q = fn({shape.x + shape.w, shape.y + shape.h})
    s.x, s.y = math.min(p[1], q[1]), math.min(p[2], q[2])
    s.w, s.h = math.abs(q[1] - p[1]), math.abs(q[2] - p[2])
    return s
end

local function xformShape(shape, fn, m)
    local t = shape.type
    local s = copy(shape)

    if t == "line" then
        s.a = fn(shape.a)
        s.b = fn(shape.b)

    elseif t == "polyline" or t == "polygon" or t == "spline" then
        s.points = mapAll(shape.points, fn)

    elseif t == "compound" then
        local cs = {}
        for i, c in ipairs(shape.contours) do cs[i] = mapAll(c, fn) end
        s.contours = cs

    elseif t == "bezier" then
        s.p0 = fn(shape.p0)
        s.p1 = fn(shape.p1)
        s.p2 = fn(shape.p2)
        s.p3 = fn(shape.p3)

    elseif t == "circle" then
        s.center = fn(shape.center)
        if rotationLike(m) or reflectionLike(m) then
            s.r = shape.r * math.sqrt(math.abs(m[1] * m[4] - m[2] * m[3]))
        elseif axisKeeping(m) then
            s.type, s.r = "ellipse", nil
            s.rx, s.ry = shape.r * math.abs(m[1]), shape.r * math.abs(m[4])
        else
            return polygonOf(ellipsePoints(shape.center, shape.r, shape.r), fn)
        end

    elseif t == "ellipse" then
        s.center = fn(shape.center)
        if axisKeeping(m) then
            s.rx, s.ry = shape.rx * math.abs(m[1]), shape.ry * math.abs(m[4])
        elseif axisSwapping(m) then
            s.rx, s.ry = shape.ry * math.abs(m[2]), shape.rx * math.abs(m[3])
        else
            return polygonOf(ellipsePoints(shape.center, shape.rx, shape.ry), fn)
        end

    elseif t == "rect" then
        local rx, ry = shape.rx, shape.ry
        if axisKeeping(m) then
            s = xformRect(shape, fn)
            s.rx = rx and rx * math.abs(m[1])
            s.ry = ry and ry * math.abs(m[4])
        elseif axisSwapping(m) then
            s = xformRect(shape, fn)
            s.rx = ry and ry * math.abs(m[2])
            s.ry = rx and rx * math.abs(m[3])
        else
            return polygonOf(rectPoints(shape), fn)
        end

    elseif t == "arc" then
        s.center = fn(shape.center)
        local k = math.sqrt(math.abs(m[1] * m[4] - m[2] * m[3]))
        local phi = atan2(m[3], m[1])
        if rotationLike(m) then
            s.r = shape.r * k
            s.startAngle = shape.startAngle + phi
            s.endAngle = shape.endAngle + phi
        elseif reflectionLike(m) then
            -- A reflection maps angle t to phi - t and reverses the sweep, so
            -- start and end swap to keep the same piece of circle.
            s.r = shape.r * k
            s.startAngle = phi - shape.endAngle
            s.endAngle = phi - shape.startAngle
        else
            error("xform: an arc cannot take a non-uniform scale", 3)
        end

    elseif t == "field" then
        if not (axisKeeping(m) and m[1] > 0 and m[4] > 0) then
            error("xform: an image only takes translation and positive axis scales", 3)
        end
        s = xformRect(shape, fn)
    end

    return s
end

local identity = {1, 0, 0, 1}

-- Translate a shape by (dx, dy).
function M.translate(shape, dx, dy)
    return xformShape(shape, function(pt)
        return {pt[1] + dx, pt[2] + dy}
    end, identity)
end

-- Rotate a shape around the origin by the given angle in radians.
-- Rects and non-circular ellipses become polygons unless the angle is a
-- multiple of a quarter turn. Arcs keep their type with both angles turned.
function M.rotate(shape, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return xformShape(shape, function(pt)
        return {pt[1] * c - pt[2] * s, pt[1] * s + pt[2] * c}
    end, {c, -s, s, c})
end

-- Rotate a shape around a pivot point by the given angle in radians.
-- Shape types change as for rotate.
function M.rotateAround(shape, angle, pivot)
    local c, s = math.cos(angle), math.sin(angle)
    local px, py = pivot[1], pivot[2]
    return xformShape(shape, function(pt)
        local dx, dy = pt[1] - px, pt[2] - py
        return {px + dx * c - dy * s, py + dx * s + dy * c}
    end, {c, -s, s, c})
end

-- Scale a shape from the origin. If sy is omitted, scales uniformly.
-- A circle under a non-uniform scale becomes an ellipse. An arc raises an
-- error unless |sx| equals |sy|.
function M.scale(shape, sx, sy)
    sy = sy or sx
    return xformShape(shape, function(pt)
        return {pt[1] * sx, pt[2] * sy}
    end, {sx, 0, 0, sy})
end

-- Scale a shape around a pivot point. Shape types change as for scale.
function M.scaleAround(shape, sx, sy, pivot)
    local px, py = pivot[1], pivot[2]
    return xformShape(shape, function(pt)
        return {px + (pt[1] - px) * sx, py + (pt[2] - py) * sy}
    end, {sx, 0, 0, sy})
end

-- Reflect a shape across the Y axis (negate x).
function M.reflectX(shape)
    return xformShape(shape, function(pt)
        return {-pt[1], pt[2]}
    end, {-1, 0, 0, 1})
end

-- Reflect a shape across the X axis (negate y).
function M.reflectY(shape)
    return xformShape(shape, function(pt)
        return {pt[1], -pt[2]}
    end, {1, 0, 0, -1})
end

-- Reflect a shape across an arbitrary axis through center at the given angle.
-- Rects and non-circular ellipses become polygons unless the axis is a
-- multiple of 45 degrees.
function M.reflect(shape, center, angle)
    local px, py = center[1], center[2]
    local c2 = math.cos(2 * angle)
    local s2 = math.sin(2 * angle)
    return xformShape(shape, function(pt)
        local dx, dy = pt[1] - px, pt[2] - py
        return {px + dx * c2 + dy * s2, py + dx * s2 - dy * c2}
    end, {c2, s2, s2, -c2})
end

return M
