-- sim-physarum.lua: slime mold transport network (Jones 2010) wired up
-- between scattered food sources, like the Tokyo rail experiment.
-- Food is a field of blobs added to the trail every step, so the
-- network settles into paths joining the sources.

local gen = require("genpuin")

local W, H = 800, 800
gen.seed(11)

local c = gen.canvas(W, H)
gen.background(c, gen.hex("#07080d"))

local foodRes = 200
local s = foodRes / W
local sites = {}
for i = 1, 16 do
    local a = i * gen.GOLDEN_ANGLE
    local r = 250 * math.sqrt(i / 16) * gen.randRange(0.8, 1.05)
    sites[i] = {W / 2 + r * math.cos(a), H / 2 + r * math.sin(a), gen.randRange(5, 11)}
end
local food = gen.field(foodRes, foodRes)
food:fill(function(x, y)
    local v = 0
    for _, p in ipairs(sites) do
        local dx, dy = x - p[1] * s, y - p[2] * s
        local sig = p[3] * s
        v = v + math.exp(-(dx * dx + dy * dy) / (2 * sig * sig))
    end
    return v * 3
end)

local trail = gen.physarum{
    w = W, h = H, agents = 450000, steps = 600, spawn = "disc",
    sensorAngle = math.rad(45), sensorDist = 20, turn = math.rad(20),
    deposit = 1, decay = 0.05, diffuse = 0.5,
    food = food,
}

local palette = {
    {0.00, gen.hex("#07080d")},
    {0.25, gen.hex("#10303d")},
    {0.55, gen.hex("#2f7f85")},
    {0.80, gen.hex("#e3b25a")},
    {1.00, gen.hex("#fff4dc")},
}
gen.draw(c, gen.image(trail, 0, 0, W, H, {palette = palette, tone = "log", toneK = 60}))

for _, p in ipairs(sites) do
    gen.draw(c, gen.circle({p[1], p[2]}, p[3] * 0.9), {stroke = gen.hex("#fff4dc"), strokeWidth = 1.2, opacity = 0.7})
end

return c
