-- sim-rd.lua: a Gray-Scott labyrinth that dissolves into dividing cells
-- and then into bare paper. The kill rate rises with distance from an
-- off-center focus, warped by noise, so the pattern finds its own edge.

local gen = require("genpuin")

local W, H = 800, 800
local N = 640
gen.seed(7)
gen.noiseSeed(7)

local c = gen.canvas(W, H)
local paper = gen.hex("#efe6d6")
gen.background(c, paper)

local fx, fy = N * 0.46, N * 0.52
local kill = gen.field(N, N)
kill:fill(function(x, y)
    local wob = gen.fbm(x * 0.006, y * 0.006, 3) * 0.35
    local r = math.sqrt((x - fx) ^ 2 + (y - fy) ^ 2) / (N * 0.5) + wob
    local t = gen.clamp((r - 0.35) / 0.75, 0, 1)
    t = t * t * (3 - 2 * t)
    return 0.0595 + 0.0105 * t
end)

local feed = gen.field(N, N)
feed:fill(function(x, y)
    return 0.037 + 0.006 * gen.fbm(x * 0.004 + 9, y * 0.004, 2)
end)

local b = gen.reactionDiffusion{
    w = N, h = N, wrap = false,
    feedMap = feed, killMap = kill,
    seeds = 120, seedRadius = 4,
    steps = 7000,
}

local ink = {
    {0.00, paper},
    {0.20, gen.hex("#ecc8a8")},
    {0.45, gen.hex("#c8643f")},
    {0.70, gen.hex("#6b2436")},
    {1.00, gen.hex("#1d1b31")},
}
gen.draw(c, gen.image(b, 0, 0, W, H, {palette = ink, range = {0.02, 0.42}}))

return c
