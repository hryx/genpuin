-- test-xform.lua: shape transforms keep arcs, rects and ellipses on the
-- geometry they describe, checked against the transformed sample points.

local T = require("test.testkit")
local check = T.check

local function close(p, q, tol)
    tol = tol or 1e-9
    return math.abs(p[1] - q[1]) < tol and math.abs(p[2] - q[2]) < tol
end

local function arcPoint(a, t)
    local th = a.startAngle + (a.endAngle - a.startAngle) * t
    return {a.center[1] + a.r * math.cos(th), a.center[2] + a.r * math.sin(th)}
end

-- The transformed arc must pass through the transformed start, middle and
-- end of the original. Start and end may swap places under a reflection.
local function sameArc(name, got, src, fn)
    local s, m, e = fn(arcPoint(src, 0)), fn(arcPoint(src, 0.5)), fn(arcPoint(src, 1))
    local gs, gm, ge = arcPoint(got, 0), arcPoint(got, 0.5), arcPoint(got, 1)
    local ends = (close(gs, s) and close(ge, e)) or (close(gs, e) and close(ge, s))
    local sweep = math.abs(math.abs(got.endAngle - got.startAngle) - math.abs(src.endAngle - src.startAngle))
    check(name, got.type == "arc" and ends and close(gm, m) and sweep < 1e-9,
        string.format("start %.3f end %.3f r %.3f center (%.3f, %.3f)",
            got.startAngle, got.endAngle, got.r, got.center[1], got.center[2]))
end

local function rot(angle, pivot)
    local c, s = math.cos(angle), math.sin(angle)
    pivot = pivot or {0, 0}
    return function(p)
        local dx, dy = p[1] - pivot[1], p[2] - pivot[2]
        return {pivot[1] + dx * c - dy * s, pivot[2] + dx * s + dy * c}
    end
end

local arc = gen.arc({30, 10}, 12, 0.2, 1.4)

print("Arcs")
sameArc("rotate turns both angles", gen.rotate(arc, 0.7), arc, rot(0.7))
check("rotate adds the angle", math.abs(gen.rotate(arc, 0.7).startAngle - 0.9) < 1e-12
    and math.abs(gen.rotate(arc, 0.7).endAngle - 2.1) < 1e-12)
sameArc("rotateAround turns both angles", gen.rotateAround(arc, -2.1, {5, 7}), arc, rot(-2.1, {5, 7}))
sameArc("reflectX mirrors the sweep", gen.reflectX(arc), arc, function(p) return {-p[1], p[2]} end)
sameArc("reflectY mirrors the sweep", gen.reflectY(arc), arc, function(p) return {p[1], -p[2]} end)
local axis = 0.4
sameArc("reflect mirrors the sweep", gen.reflect(arc, {3, -2}, axis), arc, function(p)
    local c2, s2 = math.cos(2 * axis), math.sin(2 * axis)
    local dx, dy = p[1] - 3, p[2] + 2
    return {3 + dx * c2 + dy * s2, -2 + dx * s2 - dy * c2}
end)
sameArc("uniform scale scales the radius", gen.scale(arc, 2.5), arc, function(p) return {p[1] * 2.5, p[2] * 2.5} end)
sameArc("negative uniform scale is a half turn", gen.scale(arc, -2), arc, function(p) return {-2 * p[1], -2 * p[2]} end)
sameArc("scale(-1, 1) is a reflection", gen.scale(arc, -1, 1), arc, function(p) return {-p[1], p[2]} end)
sameArc("scaleAround with a uniform factor", gen.scaleAround(arc, 0.5, 0.5, {1, 2}), arc,
    function(p) return {1 + (p[1] - 1) * 0.5, 2 + (p[2] - 2) * 0.5} end)
check("non-uniform scale on an arc raises", not pcall(gen.scale, arc, 2, 1))

print("Rects, ellipses, circles")
local rect = gen.rect(10, 20, 30, 8)
local rr = gen.rotate(rect, 0.3)
local corners = {{10, 20}, {40, 20}, {40, 28}, {10, 28}}
local ok = rr.type == "polygon" and #rr.points == 4
for i, c in ipairs(corners) do ok = ok and close(rr.points[i], rot(0.3)(c)) end
check("rotated rect becomes the rotated corner polygon", ok)
local rq = gen.rotateAround(rect, math.pi / 2, {10, 20})
check("quarter turn keeps a rect", rq.type == "rect" and close({rq.x, rq.y}, {2, 20}, 1e-9)
    and math.abs(rq.w - 8) < 1e-9 and math.abs(rq.h - 30) < 1e-9,
    string.format("%s x %s y %s w %s h %s", rq.type, tostring(rq.x), tostring(rq.y), tostring(rq.w), tostring(rq.h)))
local rs = gen.scale(rect, -2, 1)
check("negative scale keeps a rect with positive size", rs.type == "rect" and rs.x == -80 and rs.w == 60 and rs.h == 8)
local round = gen.rotate(gen.rect(0, 0, 20, 10, 3), 0.5)
local inside = true
for _, p in ipairs(round.points) do
    local q = rot(-0.5)(p)
    inside = inside and q[1] > -1e-9 and q[1] < 20 + 1e-9 and q[2] > -1e-9 and q[2] < 10 + 1e-9
end
check("rotated rounded rect stays on the rect", round.type == "polygon" and #round.points > 16 and inside)

local el = gen.ellipse({0, 0}, 20, 5)
local er = gen.rotate(el, 0.6)
local onEllipse = er.type == "polygon"
for _, p in ipairs(er.points) do
    local q = rot(-0.6)(p)
    onEllipse = onEllipse and math.abs((q[1] / 20) ^ 2 + (q[2] / 5) ^ 2 - 1) < 1e-9
end
check("rotated ellipse becomes a polygon on the ellipse", onEllipse)
local eq = gen.rotate(el, math.pi / 2)
check("quarter turn swaps ellipse radii", eq.type == "ellipse" and math.abs(eq.rx - 5) < 1e-9 and math.abs(eq.ry - 20) < 1e-9)
local es = gen.scale(el, 2, -3)
check("axis scale scales ellipse radii", es.type == "ellipse" and es.rx == 40 and es.ry == 15)
local cs = gen.scale(gen.circle({1, 1}, 4), 2, 3)
check("non-uniform scale turns a circle into an ellipse", cs.type == "ellipse" and cs.rx == 8 and cs.ry == 12)
check("uniform scale scales a circle", gen.scale(gen.circle({1, 1}, 4), 3).r == 12)

print("Render")
local W = 100
gen.canvas(W, W)
gen.background({1, 1, 1})
gen.draw(gen.rotateAround(gen.arc({50, 50}, 40, 0, math.pi / 2), math.pi, {50, 50}), {fill = {0, 0, 0}})
gen.exportPpm("out/test/test-xform.ppm")
local pixels = T.readPpm("out/test/test-xform.ppm")
check("half-turned quarter pie covers the upper left", T.gray(pixels, 30, 30) == 0, "gray " .. T.gray(pixels, 30, 30))
check("and leaves its old quadrant empty", T.gray(pixels, 70, 70) == 255, "gray " .. T.gray(pixels, 70, 70))
check("and leaves the other quadrants empty", T.gray(pixels, 70, 30) == 255 and T.gray(pixels, 30, 70) == 255)

T.summary()
