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

function M.rect(x, y, w, h)
    return {type = "rect", x = x, y = y, w = w, h = h}
end

function M.bezier(p0, p1, p2, p3)
    return {type = "bezier", p0 = p0, p1 = p1, p2 = p2, p3 = p3}
end

return M
