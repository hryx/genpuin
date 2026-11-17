-- Diffusion-limited aggregation drawn as a tree, thick where many particles
-- hang off a branch. Shows gen.dla.

local W, H = 800, 800
gen.seed(5)

local c = gen.canvas(W, H)
gen.background(c, gen.hex("#f2eee6"))

local segs = gen.dla{n = 7000, radius = 1.3, seeds = {{W / 2, H / 2}}}

local maxDepth = 1
for _, s in ipairs(segs) do maxDepth = math.max(maxDepth, s.depth) end

local root = gen.hex("#1e2340")
local tip = gen.hex("#c2563a")
for _, s in ipairs(segs) do
    local t = (s.depth / maxDepth) ^ 0.8
    gen.draw(c, gen.line(s[1], s[2]), {
        stroke = gen.lerpColor(root, tip, t),
        strokeWidth = 0.6 + 0.55 * math.log(s.weight),
        lineCap = "round",
    })
end

return c
