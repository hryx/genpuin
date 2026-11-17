-- sim-growth.lua: differential growth of a closed loop. The loop never
-- crosses itself, so filling it splits the page into two interlocking
-- territories, like a brain coral. Each earlier stage is filled on top
-- in a lighter tone, which bands the coral like agate.

local gen = require("genpuin")

local W, H = 800, 800
gen.seed(21)

local c = gen.canvas(W, H)
local paper = gen.hex("#efe7da")
gen.background(c, paper)

local loop = {}
for i = 1, 40 do
    local a = (i - 1) / 40 * 2 * math.pi
    loop[i] = {W / 2 + 18 * math.cos(a), H / 2 + 18 * math.sin(a)}
end

local opts = {
    points = loop,
    maxEdge = 4.2, restLength = 3.5, repelRadius = 14,
    repel = 1, attract = 0.6, align = 0.2, noise = 0.05, growth = 0.01,
    maxNodes = 17000,
}

local stages = {}
for i, steps in ipairs({70, 70, 70, 90, 150}) do
    opts.steps = steps
    opts.points = gen.differentialGrowth(opts)
    stages[i] = opts.points
end
-- Newest stage first, so each older and smaller loop lands on top of
-- the one that grew out of it.
local tones = {"#2d2a3e", "#5b3346", "#8f3f3f", "#c0643f", "#e3a467"}
for i = #stages, 1, -1 do
    gen.draw(c, gen.polygon(stages[i]), {
        fill = gen.hex(tones[#stages - i + 1]),
        stroke = gen.hex("#1d1b29"), strokeWidth = 0.6,
    })
end

return c
