-- texture-noise.lua: domain-warped fBm, like marbled paper, with curl
-- noise streamlines drifting over it.

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0d1b2a"))
gen.seed(8)
gen.noiseSeed(8)

local marble = gen.noiseGrid(W, H, {
    scale = 0.0025,
    octaves = 5,
    warp = 0.8,
    warpOctaves = 2,
    warpDepth = 2,
})

local palette = {
    {0.00, gen.hex("#0d1b2a")},
    {0.35, gen.hex("#1b3a5c")},
    {0.55, gen.hex("#3f7f8c")},
    {0.72, gen.hex("#f4ecd8")},
    {0.86, gen.hex("#c76b3e")},
    {1.00, gen.hex("#4a1f1a")},
}
gen.draw(c, gen.image(marble, 0, 0, W, H, {palette = palette}))

local paths = gen.traceFlow({
    bounds = {0, 0, W, H},
    n = 700,
    steps = 160,
    stepSize = 1.5,
    scale = 0.004,
    octaves = 2,
})
for _, pts in ipairs(paths) do
    if #pts > 20 then
        gen.draw(c, gen.polyline(pts), {
            stroke = gen.hex("#f4ecd8"), strokeWidth = 0.7, fill = "none", opacity = 0.5,
        })
    end
end

return c
