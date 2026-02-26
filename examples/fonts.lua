-- fonts.lua — Three text rendering styles side by side
-- Each row uses a different module: Poisson, Dot Matrix, Ants

local gen = require("genpuin")
local poissonText = require("examples.poisson-text")
local dotmatrixText = require("examples.dotmatrix-text")
local antsText = require("examples.ants-text")

local W, H = 5900, 650
local c = gen.canvas(W, H)
gen.background(c, gen.rgb(0, 0, 0))
gen.seed(42)

local lineHeight = 180
local pangram = "PACK MY BOX WITH FIVE DOZEN LIQUOR JUGS"

-- Row 1: Poisson disk style
local pts = gen.poissonDisk({0, 0, W, H}, 8)
poissonText.draw(c, pangram, {
    x = 15, y = 15,
    lineHeight = lineHeight,
    points = pts,
    color = gen.rgb(1, 1, 1),
})

-- Row 2: Dot matrix style
dotmatrixText.draw(c, pangram, {
    x = 15, y = 225,
    lineHeight = lineHeight,
    color = gen.rgb(1, 1, 1),
    dotScale = 0.35,
    noiseScale = 0.15,
})

-- Row 3: Ants style
antsText.draw(c, pangram, {
    x = 15, y = 440,
    lineHeight = lineHeight,
    color = gen.rgb(1, 1, 1),
    density = 0.9,
    spread = lineHeight * 0.025,
})

gen.exportSvg(c, "out/fonts.svg")
local scale = tonumber(arg and arg[1]) or 1
gen.exportPpm(c, "out/fonts.ppm", scale)
print(string.format("Wrote out/fonts.svg and out/fonts.ppm (scale=%g)", scale))
