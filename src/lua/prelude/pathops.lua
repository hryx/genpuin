-- Path operations on shapes: booleans, signed distance fields, contours,
-- offsets, hatching, simplification and plotter path ordering. The
-- algorithms and the shape reading are in Zig (src/pathops/ and
-- src/lua/bind_pathops.zig). Closed shapes are polygon, compound, rect,
-- circle, ellipse, a raw list of points, or a list of any of these.

local import = ...
local core = import("core")
local rand = import("rand")

local P = core.pathops

local M = {}

-- Closed contours of a shape as a list of point lists, or nil for an open
-- shape. Circles, ellipses and rects are flattened so the chord sag stays
-- near 0.05 units.
M.toContours = P.toContours

-- Boolean operation on two closed shapes: op is "union", "intersect",
-- "difference" or "xor". b may be nil to clean up a single shape. Inputs
-- may be concave, self-intersecting or have holes. opts.rule = "evenodd"
-- reads the inputs with the even-odd rule instead of nonzero. Returns a
-- compound shape. Martinez-Rueda-Feito plane sweep, exact on shared
-- vertices and overlapping edges.
M.clip = P.clip

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
    local contours = P.toContours(shape)
    if not contours then
        error("sdPolygon: expected a closed shape, got " .. tostring(shape.type), 2)
    end
    return {sdf = "polygon", contours = contours, rule = opts and opts.rule}
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
    return P.sdfEval(node, p[1], p[2])
end

-- Evaluate a distance node over a scene rect into a Field.
-- opts.rect = {x, y, w, h} (default {0, 0, 256, 256}), opts.cols = grid
-- width (default 256), opts.rows (default from the rect's aspect).
M.sdfField = P.sdfField

-- Contour lines of a Field at one level or a list of levels, by marching
-- squares with saddle disambiguation. opts.rect = {x, y, w, h} maps the
-- field onto the scene like gen.image does (default one unit per cell).
-- opts.simplify = tolerance thins the points. Returns shapes: polygons
-- for closed lines, polylines for lines that run off the field, each with
-- .level and .closed set.
M.contours = P.contours

-- Grow (distance > 0) or shrink (distance < 0) a closed shape, or outline
-- line work (lines, polylines, or a list mixing them with closed shapes)
-- at that distance. Exact polygon distance traced on a grid.
-- opts.resolution = grid cell in scene units (default extent / 512),
-- opts.tolerance = simplification (default a fifth of a cell), opts.rule.
-- Returns a compound shape.
M.offset = P.offset

-- Several offsets from one distance field: distances is a list, or
-- {step = s, count = n} for n rings s apart starting at s (negative step
-- goes inward, opts.start shifts them all). Same opts as gen.offset.
-- Returns a list of compounds, each with its .distance.
M.offsets = P.offsets

-- Fill a closed shape with parallel lines. opts: angle (radians, default 0),
-- spacing (default 4), offset (shifts the line lattice), inset (shrink the
-- region first), jitter (0..0.5 of spacing, random per line), cross = true
-- for a second pass at 90 degrees, rule = "nonzero" or "evenodd", seed.
-- Returns line shapes, or polylines zigzagging end to end when
-- opts.connect = true.
function M.hatch(shape, opts)
    opts = opts or {}
    local out, err = P.hatch(shape, opts, opts.seed or rand.randInt(1, 2147483646))
    if out == nil then error(err, 2) end
    return out
end

-- Clip line work (a line, polyline, closed shape outline or a list of
-- them) to the inside of a closed shape, or the outside when
-- opts.outside = true. opts.rule as in gen.clip. Returns polylines.
M.clipLines = P.clipLines

-- Fewer points within tolerance: Ramer-Douglas-Peucker, or
-- Visvalingam-Whyatt with opts.method = "area" (drops points whose
-- triangle is smaller than tolerance squared). opts may also be the method
-- string. Works on polylines, polygons, compounds and other closed shapes.
M.simplify = P.simplify

-- Reorder line work to cut pen-up travel for plotters: greedy nearest
-- neighbor on a grid of endpoints, then bounded 2-opt. Paths are flipped
-- where that helps. list holds lines, polylines and polygons. opts.start =
-- pen position (default {0, 0}), opts.budget = 2-opt move evaluations
-- (default 4e6). Returns the reordered list, then the travel distance
-- before and after.
M.orderPaths = P.orderPaths

-- Merge lines and polylines whose endpoints lie within tolerance (default
-- 1e-9) into longer polylines. Chains that close on themselves come back
-- as polygons.
M.joinPaths = P.joinPaths

return M
