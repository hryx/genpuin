-- debug-spiral.lua — Fronds sprouting along a stem

local gen = require("genpuin")

local W, H = 600, 1000
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#111111"))
gen.seed(12)

-- Draw a frond as a turtle walk, with recursive sub-fronds.
-- ox, oy: base position
-- heading: initial direction (radians)
-- size: scale factor (1.0 = full size)
-- flip: if true, mirror the curvature direction
-- level: recursion depth (1 = main, 2 = sub-frond, 3 = sub-sub-frond)
local function frond(ox, oy, heading, size, flip, level)
    level = level or 1
    local step = 2 * size
    local n = math.floor(200 * size)
    local radius = ({1.5, 0.8, 0.4})[level]
    local curvRate = ({0.15, 0.25, 0.35})[level]
    local curvDir = flip and -1 or 1
    -- Spawn sub-fronds first so they draw behind the parent
    if level < 3 then
        local subCount = level == 1 and 5 or 3
        for si = 1, subCount do
            local spawnT = 0.2 + 0.6 * (si - 1) / (subCount - 1)
            local spawnN = math.floor(spawnT * n)
            local sx, sy = ox, oy
            local sh = heading
            for i = 0, spawnN - 1 do
                local t = i / (n - 1)
                sx = sx + step * math.cos(sh)
                sy = sy + step * math.sin(sh)
                sh = sh + curvDir * t * t * t * curvRate
            end
            local subScale = level == 1 and 0.35 or 0.5
            local subSize = size * subScale
            frond(sx, sy, sh, subSize, not flip, level + 1)
        end
    end
    -- Draw this frond's dots on top
    local x, y = ox, oy
    local h = heading
    local frondColor = ({
        gen.hsv(0.30, 0.7, 0.5),
        gen.hsv(0.18, 0.7, 0.65),
        gen.hsv(0.06, 0.7, 0.7),
    })[level]
    for i = 0, n - 1 do
        local t = i / (n - 1)
        gen.draw(c, gen.circle({x, y}, radius), {
            fill = frondColor,
        })
        x = x + step * math.cos(h)
        y = y + step * math.sin(h)
        h = h + curvDir * t * t * t * curvRate
    end
end

-- Vertical stem from bottom to top
local stemX = W / 2
local stemBottom = H - 40
local stemTop = stemBottom - 680
local stemLen = stemBottom - stemTop

-- Umbrella curve: logarithmic  y = 1 + ln(1 - x^2)
-- Sharp smooth peak at center, vertical asymptotes at edges (no flaring).
local umbrellaBase = stemBottom + 20  -- ground level for rain
local umbrellaPeak = stemTop - 100    -- highest point (above top frond)
local halfWidth = W / 3               -- distance from center to asymptote

local function umbrellaY(x)
    local dx = (x - stemX) / halfWidth
    local dx2 = dx * dx
    if dx2 >= 1 then return umbrellaBase end
    local y = umbrellaPeak - (umbrellaBase - umbrellaPeak) * math.log(1 - dx2)
    return math.min(y, umbrellaBase)
end

-- Raindrops — formulaic dashed vertical lines
-- Origins oscillate with a sinusoidal y-pattern at the top.
-- All streams have the same length, so bottoms oscillate too.
-- Streams are clipped by the umbrella curve.
local rainSpacing = 72
local sinAmp = 12
local sinFreq = 0.04
local streamLen = 950

-- Three levels of rain: main, mid, fine
-- Base grid at 1/4 of main spacing; level determined by divisibility.
local baseSpacing = rainSpacing / 4
local nStreams = math.floor((W - 40) / baseSpacing)
for i = 0, nStreams do
    local rx = 20 + i * baseSpacing
    local level
    if i % 4 == 0 then level = 1
    elseif i % 2 == 0 then level = 2
    else level = 3
    end

    local width = ({3, 1.2, 0.4})[level]
    local dashLen = ({3, 2, 1.5})[level]
    local gapLen = ({24, 20, 16})[level]

    local ryTop = 25 + sinAmp * math.sin(rx * sinFreq)
    local ryBottom = math.min(ryTop + streamLen, umbrellaY(rx))

    if ryBottom > ryTop + 20 then
        local rainLine = gen.line({rx, ryTop}, {rx, ryBottom})
        local dashes = gen.dash(rainLine, dashLen, gapLen)
        for _, seg in ipairs(dashes) do
            local rainColor = ({
                gen.hsv(0.58, 0.3, 0.7),
                gen.hsv(0.56, 0.25, 0.6),
                gen.hsv(0.54, 0.2, 0.5),
            })[level]
            gen.draw(c, seg, {
                stroke = rainColor,
                strokeWidth = width,
                strokeLinecap = "round",
            })
        end
    end
end

-- Debug draw: umbrella curve (red, thin)
-- local umbrellaPts = {}
-- for x = 0, W, 2 do
--     umbrellaPts[#umbrellaPts + 1] = {x, umbrellaY(x)}
-- end
-- gen.draw(c, gen.polyline(umbrellaPts), {
--     stroke = gen.hex("#ff0000"),
--     strokeWidth = 1,
-- })

-- Fronds alternate left and right along the stem
local nFronds = 12
for i = 0, nFronds - 1 do
    local t = i / (nFronds - 1)  -- 0 = bottom, 1 = top
    local sy = stemBottom - t * stemLen
    local size = gen.lerp(1.0, 0.3, t)
    local flip = i % 2 == 1
    frond(stemX, sy, -math.pi / 2, size, flip)
end

-- Draw solid stem between bottom-most and top-most frond origins
gen.draw(c, gen.line({stemX, stemBottom}, {stemX, stemTop}), {
    stroke = gen.hsv(0.30, 0.6, 0.55),
    strokeWidth = 3,
    strokeLinecap = "round",
})

return c
