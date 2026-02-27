-- fonts.lua — Three text rendering styles side by side
-- Each row uses a different module: Scratch, Dot Matrix, Ants

local gen = require("genpuin")
local scratchText = require("examples.text-scratch")
local dotmatrixText = require("examples.text-dotmatrix")
local antsText = require("examples.text-ants")

local W, H = 4000, 820
local c = gen.canvas(W, H)
gen.background(c, gen.rgb(0, 0, 0))
gen.seed(42)

local lineHeight = 180
local pangram = "PACK MY BOX WITH FIVE DOZEN LIQUOR JUGS"

-- Row 1: Scratch style (Poisson disk grid)
local pts = gen.poissonDisk({0, 0, W, H}, 8)
scratchText.draw(c, pangram, {
    x = 15, y = 15,
    lineHeight = lineHeight,
    points = pts,
    color = gen.rgb(1, 1, 1),
})

-- Rows 2-3: Dot matrix style (split into two lines)
dotmatrixText.draw(c, "PACK MY BOX WITH FIVE", {
    x = 15, y = 215,
    lineHeight = lineHeight,
    color = gen.rgb(1, 1, 1),
    dotScale = 0.35,
    noiseScale = 0.15,
})
dotmatrixText.draw(c, "DOZEN LIQUOR JUGS", {
    x = 15, y = 415,
    lineHeight = lineHeight,
    color = gen.rgb(1, 1, 1),
    dotScale = 0.35,
    noiseScale = 0.15,
})

-- Row 4: Ants style (curvy bezier paths)
antsText.draw(c, pangram, {
    x = 15, y = 615,
    lineHeight = lineHeight,
    color = gen.rgb(1, 1, 1),
    density = 0.9,
    spread = lineHeight * 0.025,
})

return c
