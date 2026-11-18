-- test-stipple.lua: gen.stipple on every shape type, checked against each
-- shape's own definition, and the path functions on curved shapes.

local T = require("test.testkit")
local check = T.check

local function errorOf(fn)
    local ok, err = pcall(fn)
    if ok then return nil end
    return err
end

local function all(dots, pred)
    for _, d in ipairs(dots) do
        if not pred(d[1], d[2]) then return false, string.format("dot at %.3f, %.3f", d[1], d[2]) end
    end
    return true
end

local function stippleCheck(name, shape, density, pred, area)
    gen.seed(1)
    local dots = gen.stipple(shape, density)
    local ok, why = all(dots, pred)
    check(name .. ": dots inside", #dots > 0 and ok, why or "no dots")
    if area then
        local want = area * density
        check(name .. ": count follows the area", math.abs(#dots - want) < 0.1 * want,
            string.format("%d dots, want about %.0f", #dots, want))
    end
    return dots
end

print("Stipple on each shape type")
stippleCheck("circle", gen.circle({50, 40}, 20), 0.5, function(x, y)
    return (x - 50) ^ 2 + (y - 40) ^ 2 <= 400
end, math.pi * 400)
stippleCheck("ellipse", gen.ellipse({50, 40}, 30, 10), 0.5, function(x, y)
    return ((x - 50) / 30) ^ 2 + ((y - 40) / 10) ^ 2 <= 1
end, math.pi * 300)
stippleCheck("rect", gen.rect(10, 20, 40, 30), 0.5, function(x, y)
    return x >= 10 and x <= 50 and y >= 20 and y <= 50
end, 1200)
local r = 10
local rounded = stippleCheck("rounded rect", gen.rect(0, 0, 60, 40, r), 1, function(x, y)
    if x < 0 or x > 60 or y < 0 or y > 40 then return false end
    local cx = math.max(r, math.min(60 - r, x))
    local cy = math.max(r, math.min(40 - r, y))
    return (x - cx) ^ 2 + (y - cy) ^ 2 <= r * r
end, 2400 - (4 - math.pi) * r * r)
local cornerFree = true
for _, d in ipairs(rounded) do
    if d[1] < 2 and d[2] < 2 then cornerFree = false end
end
check("rounded rect: the corner is cut", cornerFree)
stippleCheck("arc as a pie slice", gen.arc({0, 0}, 30, 0.25, 2), 1, function(x, y)
    local a = math.atan2 and math.atan2(y, x) or math.atan(y, x)
    return x * x + y * y <= 900 and a >= 0.25 and a <= 2
end, 0.5 * 900 * 1.75)
stippleCheck("arc swept backwards", gen.arc({0, 0}, 30, 2, 0.25), 1, function(x, y)
    local a = math.atan2 and math.atan2(y, x) or math.atan(y, x)
    return x * x + y * y <= 900 and a >= 0.25 and a <= 2
end, 0.5 * 900 * 1.75)
local ring = gen.compound({
    {{0, 0}, {30, 0}, {30, 30}, {0, 30}},
    {{10, 10}, {10, 20}, {20, 20}, {20, 10}},
})
stippleCheck("compound with a hole", ring, 1, function(x, y)
    local inOuter = x >= 0 and x <= 30 and y >= 0 and y <= 30
    local inHole = x > 10 and x < 20 and y > 10 and y < 20
    return inOuter and not inHole
end, 800)
stippleCheck("polygon", gen.polygon({{0, 0}, {40, 0}, {0, 40}}), 1, function(x, y)
    return x + y <= 40
end, 800)
stippleCheck("polyline fills its box", gen.polyline({{0, 0}, {40, 0}, {40, 20}}), 0.5, function(x, y)
    return x >= 0 and x <= 40 and y >= 0 and y <= 20
end, 800)
stippleCheck("line fills its box", gen.line({0, 0}, {20, 10}), 1, function(x, y)
    return x >= 0 and x <= 20 and y >= 0 and y <= 10
end, 200)
-- The curve peaks at y = 30 for t = 0.5, inside its control points.
local bez = stippleCheck("bezier fills its curve's box", gen.bezier({0, 0}, {0, 40}, {40, 40}, {40, 0}), 1,
    function(x, y) return x >= 0 and x <= 40 and y >= 0 and y <= 30 end, 1200)
local top = 0
for _, d in ipairs(bez) do top = math.max(top, d[2]) end
check("bezier box reaches the peak", top > 29.5, string.format("highest dot %.3f", top))
stippleCheck("spline fills its curve's box", gen.spline({{0, 0}, {20, 20}, {40, 0}}), 1, function(x, y)
    return x >= 0 and x <= 40 and y >= 0 and y <= 20.001
end)

print("\nRandom stream")
gen.seed(9)
local a = gen.stipple(gen.circle({0, 0}, 10), 0.3)
local nextA = gen.rand()
gen.seed(9)
local b = gen.stipple(gen.circle({0, 0}, 10), 0.3)
local same = #a == #b
for i = 1, #a do same = same and a[i][1] == b[i][1] and a[i][2] == b[i][2] end
check("same seed, same dots", same and gen.rand() == nextA)
-- Every shape draws floor(w * h * density) dots over its box, x then y,
-- kept or not: here 20 * 20 * 0.3 = 120 dots, 240 numbers.
gen.seed(9)
local first = {}
for i = 1, 240 do first[i] = gen.rand() end
local after = gen.rand()
check("a circle takes two numbers per dot of its box", nextA == after)
check("the first dot is the first two numbers in the box",
    a[1][1] == -10 + first[1] * 20 and a[1][2] == -10 + first[2] * 20)
gen.seed(9)
gen.stipple(gen.polygon({{-10, -10}, {10, -10}, {10, 10}, {-10, 10}}), 0.3)
check("a polygon with the same box takes the same numbers", gen.rand() == after)

print("\nErrors")
local err = errorOf(function() local d = gen.stipple({type = "blob"}) return d end)
check("stipple names the type and the script line",
    err and err:find("test%-stipple%.lua:%d+: stipple: unsupported shape type blob") ~= nil, err)
err = errorOf(function() local d = gen.stipple(gen.image(gen.field(2, 2), 0, 0, 2, 2)) return d end)
check("stipple refuses an image", err and err:find("test%-stipple%.lua:%d+: stipple: unsupported shape type field") ~= nil, err)
err = errorOf(function() local d = gen.jitter({{0, 0}, {1, 1}}, 1) return d end)
check("jitter names the script line", err and err:find("test%-stipple%.lua:%d+: jitter: unsupported shape type nil") ~= nil, err)
err = errorOf(function() local d = gen.taper(ring, 2, 1) return d end)
check("taper refuses a compound of two contours",
    err and err:find("test%-stipple%.lua:%d+: taper: expected one path, got a compound of 2 contours") ~= nil, err)
err = errorOf(function() local d = gen.resample(ring, 5) return d end)
check("resample names itself", err and err:find("test%-stipple%.lua:%d+: resample:") ~= nil, err)

print("\nPath functions on a circle and a rect")
local circle = gen.circle({0, 0}, 20)
local square = gen.rect(0, 0, 10, 10)
local function onCircle(pts, tol)
    for _, p in ipairs(pts) do
        if math.abs(math.sqrt(p[1] ^ 2 + p[2] ^ 2) - 20) > tol then return false end
    end
    return #pts > 0
end
local function onSquare(pts)
    for _, p in ipairs(pts) do
        local x, y = p[1], p[2]
        local edge = (x == 0 or x == 10 or y == 0 or y == 10) and x >= 0 and x <= 10 and y >= 0 and y <= 10
        if not edge then return false end
    end
    return #pts > 0
end
gen.seed(2)
local j = gen.jitter(circle, 1)
check("jitter circle is a polygon near the circle", j.type == "polygon" and onCircle(j.points, 1.5))
local s = gen.smooth(square)
local inside = true
for _, p in ipairs(s.points) do inside = inside and p[1] >= 0 and p[1] <= 10 and p[2] >= 0 and p[2] <= 10 end
check("smooth rect is a polygon with cut corners", s.type == "polygon" and #s.points == 16 and inside)
local t = gen.taper(circle, 3, 1, 8)
check("taper circle goes all the way round",
    #t == 8 and t[1].shape.points[1][1] == 20 and math.abs(t[8].shape.points[2][1] - 20) < 1e-9
    and t[1].width == 3 and t[8].width == 1)
local d = gen.dash(square, 3, 2)
local allOn = true
for _, piece in ipairs(d) do allOn = allOn and onSquare(piece.points) end
check("dash rect covers every side", #d == 8 and allOn, #d .. " dashes")
local sa = gen.sampleAlong(circle, 9)
check("sampleAlong circle lies on it and closes", sa.type == "polyline" and #sa.points == 9 and onCircle(sa.points, 0.06)
    and math.abs(sa.points[9][1] - 20) < 1e-9)
local rs = gen.resample(square, 5)
check("resample rect hits its corners", rs.points[2][1] == 10 and rs.points[2][2] == 0 and rs.points[3][1] == 10
    and rs.points[3][2] == 10 and onSquare(rs.points))
local sub = gen.subdivide(square)
check("subdivide rect", sub.type == "polygon" and #sub.points == 8 and sub.points[2][1] == 5 and sub.points[8][2] == 5)
local ringSub = gen.subdivide(ring)
check("subdivide compound keeps its contours", ringSub.type == "compound" and #ringSub.contours == 2
    and #ringSub.contours[2] == 8)
local simple = gen.simplify(gen.arc({0, 0}, 20, 0, math.pi), 1)
check("simplify arc is a polyline on the arc", simple.type == "polyline" and #simple.points >= 3
    and onCircle(simple.points, 1e-9))

T.summary()
