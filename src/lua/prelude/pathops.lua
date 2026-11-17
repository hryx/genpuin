local import = ...
local core = import("core")
local rand = import("rand")

local M = {}

-- Segments for a curve of radius r, so the chord sag stays near 0.05 units.
local function arcSegments(r, sweep)
    if r <= 0 then return 1 end
    local n = math.ceil(sweep / (2 * math.acos(math.max(1 - 0.05 / r, -1))))
    return math.max(4, math.min(n, 2048))
end

local function ellipsePoints(c, rx, ry)
    local n = arcSegments(math.max(rx, ry), 2 * math.pi)
    local pts = {}
    for i = 0, n - 1 do
        local t = i / n * 2 * math.pi
        pts[#pts + 1] = {c[1] + rx * math.cos(t), c[2] + ry * math.sin(t)}
    end
    return pts
end

local function rectPoints(s)
    local rx = math.min(s.rx or 0, s.w / 2)
    local ry = math.min(s.ry or rx, s.h / 2)
    if rx <= 0 or ry <= 0 then
        return {{s.x, s.y}, {s.x + s.w, s.y}, {s.x + s.w, s.y + s.h}, {s.x, s.y + s.h}}
    end
    local pts = {}
    local corners = {
        {s.x + s.w - rx, s.y + ry, -math.pi / 2},
        {s.x + s.w - rx, s.y + s.h - ry, 0},
        {s.x + rx, s.y + s.h - ry, math.pi / 2},
        {s.x + rx, s.y + ry, math.pi},
    }
    local n = arcSegments(math.max(rx, ry), math.pi / 2)
    for _, k in ipairs(corners) do
        for i = 0, n do
            local t = k[3] + i / n * math.pi / 2
            pts[#pts + 1] = {k[1] + rx * math.cos(t), k[2] + ry * math.sin(t)}
        end
    end
    return pts
end

-- Closed contours of a shape: polygon, compound, rect, circle, ellipse, a
-- raw list of points, or a list of any of these. Returns nil for open shapes.
local function toContours(shape)
    local t = shape.type
    if t == "polygon" then return {shape.points} end
    if t == "compound" then return shape.contours end
    if t == "rect" then return {rectPoints(shape)} end
    if t == "circle" then return {ellipsePoints(shape.center, shape.r, shape.r)} end
    if t == "ellipse" then return {ellipsePoints(shape.center, shape.rx, shape.ry)} end
    if t ~= nil then return nil end
    if type(shape[1]) == "table" and type(shape[1][1]) == "number" then return {shape} end
    local out = {}
    for _, s in ipairs(shape) do
        local cs = toContours(s)
        if not cs then return nil end
        for _, c in ipairs(cs) do out[#out + 1] = c end
    end
    return out
end

local function needContours(shape, what)
    local cs = toContours(shape)
    if not cs then error(what .. ": expected a closed shape, got " .. tostring(shape.type), 3) end
    return cs
end

-- Open point paths of line work: line, polyline, spline points, and closed
-- shapes as loops that repeat their first point.
local function toPaths(shape)
    local t = shape.type
    if t == "line" then return {{shape.a, shape.b}} end
    if t == "polyline" then return {shape.points} end
    if t == nil and type(shape[1]) == "table" and shape[1].type == nil and type(shape[1][1]) == "number" then
        return {shape}
    end
    if t == nil then
        local out = {}
        for _, s in ipairs(shape) do
            for _, p in ipairs(toPaths(s)) do out[#out + 1] = p end
        end
        return out
    end
    local cs = toContours(shape)
    if not cs then error("expected line work, got " .. tostring(t), 3) end
    local out = {}
    for _, c in ipairs(cs) do
        local loop = {}
        for i, p in ipairs(c) do loop[i] = p end
        loop[#loop + 1] = c[1]
        out[#out + 1] = loop
    end
    return out
end

M.toContours = toContours

-- Boolean operation on two closed shapes (polygon, compound, rect, circle,
-- ellipse, or a list of them): op is "union", "intersect", "difference"
-- or "xor". b may be nil to clean up a single shape. Inputs may be concave,
-- self-intersecting or have holes. opts.rule = "evenodd" reads the inputs
-- with the even-odd rule instead of nonzero. Returns a compound shape.
-- Martinez-Rueda-Feito plane sweep, exact on shared vertices and overlapping
-- edges.
function M.clip(a, b, op, opts)
    opts = opts or {}
    local cb = b and needContours(b, "clip") or {}
    local out = core.pathops.clip(needContours(a, "clip"), cb, op or "union", opts.rule)
    return {type = "compound", contours = out}
end

-- Signed distance nodes. Each returns a plain table that gen.sdEval,
-- gen.sdfField and the combinators read. Negative inside.

-- Circle of radius r.
function M.sdCircle(center, r)
    return {sdf = "circle", c = center, r = r}
end

-- Box of full width w and height h around center.
function M.sdBox(center, w, h)
    return {sdf = "box", c = center, w = w, h = h or w}
end

-- Segment from a to b, thickened into a capsule of radius r (default 0).
function M.sdSegment(a, b, r)
    return {sdf = "segment", a = a, b = b, r = r or 0}
end

-- Exact distance to a closed shape or a list of points. opts.rule picks
-- "nonzero" (default) or "evenodd" for the inside.
function M.sdPolygon(shape, opts)
    return {sdf = "polygon", contours = needContours(shape, "sdPolygon"), rule = opts and opts.rule}
end

local function combine(kind, k, ...)
    local node = {sdf = kind, k = k}
    for i, c in ipairs({...}) do node[i] = c end
    return node
end

-- Union of any number of distance nodes.
function M.sdUnion(...) return combine("union", 0, ...) end

-- Intersection of any number of distance nodes.
function M.sdIntersect(...) return combine("intersect", 0, ...) end

-- a with every later node cut away.
function M.sdSubtract(a, ...) return combine("subtract", 0, a, ...) end

-- Smooth union with blend radius k, the polynomial smooth minimum from
-- Inigo Quilez (iquilezles.org/articles/smin).
function M.sdSmoothUnion(a, b, k) return combine("union", k, a, b) end

-- Smooth intersection with blend radius k.
function M.sdSmoothIntersect(a, b, k) return combine("intersect", k, a, b) end

-- Smooth subtraction of b from a with blend radius k.
function M.sdSmoothSubtract(a, b, k) return combine("subtract", k, a, b) end

-- Grow a node by r, rounding its corners.
function M.sdRound(node, r)
    return {sdf = "round", node, r = r}
end

-- Hollow a node into a shell of thickness 2t around its edge.
function M.sdOnion(node, t)
    return {sdf = "onion", node, t = t}
end

-- Move a node by offset {dx, dy}.
function M.sdTranslate(node, offset)
    return {sdf = "translate", node, offset = offset}
end

-- Rotate a node by angle radians around center (default the origin).
function M.sdRotate(node, angle, center)
    return {sdf = "rotate", node, angle = angle, center = center}
end

-- Scale a node uniformly about the origin.
function M.sdScale(node, s)
    return {sdf = "scale", node, s = s}
end

-- Repeat a node every period (a number or {px, py}, 0 skips an axis).
-- count {nx, ny} limits the copies to 0..n-1 periods from the original.
-- Exact only while each copy fits in its cell.
function M.sdRepeat(node, period, count)
    return {sdf = "repeat", node, period = period, count = count}
end

-- Distance from point p to a node.
function M.sdEval(node, p)
    return core.pathops.sdfEval(node, p[1], p[2])
end

local function rectOpts(opts, rect)
    rect = rect or opts.rect
    if not rect then return opts end
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.x, o.y, o.w, o.h = rect[1], rect[2], rect[3], rect[4]
    return o
end

-- Evaluate a distance node over a scene rect into a Field.
-- opts.rect = {x, y, w, h} (default {0, 0, 256, 256}), opts.cols = grid
-- width (default 256), opts.rows (default from the rect's aspect).
function M.sdfField(node, opts)
    return core.pathops.sdfField(node, rectOpts(opts or {}))
end

-- Contour lines of a Field at one level or a list of levels, by marching
-- squares with saddle disambiguation. opts.rect = {x, y, w, h} maps the
-- field onto the scene like gen.image does (default one unit per cell).
-- opts.simplify = tolerance thins the points. Returns shapes: polygons
-- for closed lines, polylines for lines that run off the field, each with
-- .level and .closed set.
function M.contours(field, levels, opts)
    return core.pathops.contours(field, levels, rectOpts(opts or {}))
end

local function offsetOpts(shape, opts)
    opts = opts or {}
    local cs = toContours(shape)
    local o = {resolution = opts.resolution, tolerance = opts.tolerance, rule = opts.rule}
    if not cs then
        cs = toPaths(shape)
        o.open = true
    end
    return cs, o
end

-- Grow (distance > 0) or shrink (distance < 0) a closed shape, or outline
-- a line or polyline at that distance. Exact polygon distance traced on a
-- grid. opts.resolution = grid cell in scene units (default extent / 512),
-- opts.tolerance = simplification (default a fifth of a cell), opts.rule.
-- Returns a compound shape.
function M.offset(shape, distance, opts)
    local cs, o = offsetOpts(shape, opts)
    local out = core.pathops.offsets(cs, {distance}, o)
    return {type = "compound", contours = out[1]}
end

-- Several offsets from one distance field: distances is a list, or
-- {step = s, count = n} for n rings s apart starting at s (negative step
-- goes inward). Same opts as gen.offset. Returns a list of compounds.
function M.offsets(shape, distances, opts)
    if distances.step then
        local list = {}
        for i = 1, distances.count or 1 do list[i] = (distances.start or 0) + i * distances.step end
        distances = list
    end
    local cs, o = offsetOpts(shape, opts)
    local out = {}
    for i, c in ipairs(core.pathops.offsets(cs, distances, o)) do
        out[i] = {type = "compound", contours = c, distance = distances[i]}
    end
    return out
end

-- Fill a closed shape with parallel lines. opts: angle (radians, default 0),
-- spacing (default 4), offset (shifts the line lattice), inset (shrink the
-- region first), jitter (0..0.5 of spacing, random per line), cross = true
-- for a second pass at 90 degrees, rule = "nonzero" or "evenodd", seed.
-- Returns line shapes, or polylines zigzagging end to end when
-- opts.connect = true.
function M.hatch(shape, opts)
    opts = opts or {}
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.seed = o.seed or rand.randInt(1, 2147483646)
    local out = core.pathops.hatch(needContours(shape, "hatch"), o)
    if not opts.connect then return out end
    for i, pts in ipairs(out) do out[i] = {type = "polyline", points = pts} end
    return out
end

-- Clip line work (a line, polyline, closed shape outline or a list of
-- them) to the inside of a closed shape, or the outside when
-- opts.outside = true. opts.rule as in gen.clip. Returns polylines.
function M.clipLines(lines, shape, opts)
    opts = opts or {}
    local out = core.pathops.clipLines(toPaths(lines), needContours(shape, "clipLines"), opts)
    for i, pts in ipairs(out) do out[i] = {type = "polyline", points = pts} end
    return out
end

local function simplifyPoints(pts, tolerance, closed, method)
    return core.pathops.simplify(pts, tolerance, closed, method)
end

-- Fewer points within tolerance: Ramer-Douglas-Peucker, or
-- Visvalingam-Whyatt with opts.method = "area" (drops points whose
-- triangle is smaller than tolerance squared). opts may also be the method
-- string. Works on polylines, polygons, compounds and other closed shapes.
function M.simplify(shape, tolerance, opts)
    local method = type(opts) == "string" and opts or (opts and opts.method) or "distance"
    local t = shape.type
    if t == "polyline" then
        return {type = "polyline", points = simplifyPoints(shape.points, tolerance, false, method)}
    end
    if t == "line" then return shape end
    local cs = needContours(shape, "simplify")
    local out = {}
    for i, c in ipairs(cs) do out[i] = simplifyPoints(c, tolerance, true, method) end
    if t == "compound" or #out ~= 1 then return {type = "compound", contours = out} end
    return {type = "polygon", points = out[1]}
end

local function reversedShape(s)
    local r = {}
    for k, v in pairs(s) do r[k] = v end
    if s.type == "line" then
        r.a, r.b = s.b, s.a
        return r
    end
    local pts, n = {}, #s.points
    if s.type == "polygon" then
        pts[1] = s.points[1]
        for i = 2, n do pts[i] = s.points[n + 2 - i] end
    else
        for i = 1, n do pts[i] = s.points[n + 1 - i] end
    end
    r.points = pts
    return r
end

-- Reorder line work to cut pen-up travel for plotters: greedy nearest
-- neighbour on a grid of endpoints, then bounded 2-opt. Paths are flipped
-- where that helps. list holds lines, polylines and polygons. opts.start =
-- pen position (default {0, 0}), opts.budget = 2-opt move evaluations
-- (default 4e6). Returns the reordered list, then the travel distance
-- before and after.
function M.orderPaths(list, opts)
    local ends = {}
    for i, s in ipairs(list) do
        if s.type == "line" then
            ends[i] = {s.a, s.b}
        elseif s.type == "polygon" then
            ends[i] = {s.points[1], s.points[1]}
        else
            ends[i] = {s.points[1], s.points[#s.points]}
        end
    end
    local order, reversed, before, after = core.pathops.orderPaths(ends, opts)
    local out = {}
    for i, k in ipairs(order) do
        out[i] = reversed[i] and reversedShape(list[k]) or list[k]
    end
    return out, before, after
end

-- Merge lines and polylines whose endpoints lie within tolerance (default
-- 1e-9) into longer polylines. Chains that close on themselves come back
-- as polygons.
function M.joinPaths(list, tolerance)
    local paths, closed = core.pathops.joinPaths(toPaths(list), tolerance)
    local out = {}
    for i, pts in ipairs(paths) do
        out[i] = {type = closed[i] and "polygon" or "polyline", points = pts}
    end
    return out
end

return M
