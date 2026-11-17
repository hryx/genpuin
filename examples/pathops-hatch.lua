-- A plotter still life in hatching, shapes occluding each other by boolean
-- difference. Shows gen.hatch, gen.clip and gen.orderPaths.

local W, H = 800, 800
gen.canvas(W, H)
gen.background(gen.hex("#fbfaf6"))
gen.seed(3)

local sun = gen.circle({520, 300}, 170)
local pillar = gen.rect(150, 190, 210, 470, 40)

-- A pentagram crosses itself. Under the even-odd rule its middle is a
-- window onto whatever stands behind it.
local star = {}
for i = 0, 4 do
    local t = -math.pi / 2 + i * 4 * math.pi / 5
    star[#star + 1] = {420 + 190 * math.cos(t), 560 + 190 * math.sin(t)}
end
star = gen.polygon(star)
local front = gen.clip(star, nil, "union", {rule = "evenodd"})
local pillarSeen = gen.clip(pillar, front, "difference")
local sunSeen = gen.clip(gen.clip(sun, pillar, "difference"), front, "difference")
local everything = gen.clip(gen.clip(sun, pillar, "union"), front, "union")

local work = {}
local function add(list)
    for _, s in ipairs(list) do work[#work + 1] = s end
end

add(gen.hatch(sunSeen, {angle = 0.25, spacing = 5, inset = 5, connect = true}))

add(gen.hatch(pillarSeen, {angle = -0.9, spacing = 4.5, jitter = 0.3}))
local shade = gen.clip(pillarSeen, gen.rect(270, 0, 200, 800), "intersect")
add(gen.hatch(shade, {angle = 0.7, spacing = 4.5, jitter = 0.3}))

add(gen.hatch(front, {angle = 0.1, spacing = 3.2, cross = true}))

local ground = {}
for k = 0, 24 do
    local y0 = 470 + k * 13 + k * k * 0.25
    local pts = {}
    for x = 0, W, 8 do
        pts[#pts + 1] = {x, y0 + 4 * math.sin(x * 0.02 + k * 0.7)}
    end
    ground[#ground + 1] = gen.polyline(pts)
end
add(gen.clipLines(ground, gen.offset(everything, 10), {outside = true}))

for _, shape in ipairs({sunSeen, pillarSeen, front}) do
    for _, ct in ipairs(shape.contours) do work[#work + 1] = gen.polygon(ct) end
end

local ordered = gen.orderPaths(work, {start = {0, 0}})
for _, s in ipairs(ordered) do
    gen.draw(s, {stroke = gen.hex("#20232b"), strokeWidth = 0.9, strokeLinecap = "round"})
end
