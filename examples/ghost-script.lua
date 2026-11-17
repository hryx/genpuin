-- Rows of made-up handwriting with faint retraced ghosts behind each stroke.
-- Shows gen.smooth, gen.jitter and gen.resample.

local W, H = 800, 700
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#ffffff"))
gen.seed(77)

local ROWS = 8
local COLS = 12
local CELL_W = 45
local CELL_H = 55
local MARGIN_X = (W - COLS * CELL_W) / 2
local MARGIN_Y = (H - ROWS * CELL_H) / 2

local ink = gen.rgb(0.05, 0.05, 0.1)

-- Make a wobbly closed loop (imperfect circle) from a polygon.
local function wobblyDot(cx, cy, r)
    local nSides = gen.randInt(6, 10)
    local pts = {}
    for i = 1, nSides do
        local angle = (i - 1) / nSides * math.pi * 2
        local wobble = r * gen.randRange(0.7, 1.3)
        pts[i] = {cx + math.cos(angle) * wobble, cy + math.sin(angle) * wobble}
    end
    return gen.smooth(gen.polygon(pts), 2)
end

-- Draw a pen splatter at position (sx, sy) with given intensity (0-1).
local function drawSplatter(sx, sy, intensity)
    local mainR = gen.randRange(1.5, 3) + intensity * 5
    -- Main blot
    gen.draw(c, gen.circle({sx, sy}, mainR), {
        fill = ink, opacity = gen.randRange(0.15, 0.35),
    })
    -- Satellite droplets, count scales with intensity
    local nDrops = gen.randInt(1, math.floor(2 + intensity * 8))
    for _ = 1, nDrops do
        local dp = gen.randInCircle({sx, sy}, mainR * gen.randRange(1.5, 3.5))
        local dr = gen.randRange(0.3, 1.0 + intensity * 1.5)
        gen.draw(c, gen.circle(dp, dr), {
            fill = ink, opacity = gen.randRange(0.1, 0.3),
        })
    end
end

-- Generate a single character stroke as a smoothed polyline.
-- cx, cy: top-left corner of the character cell.
-- idx: unique index for perlin variation.
-- Returns strokes list and the first point of the main stroke.
local function makeGlyph(cx, cy, idx)
    local nPts = gen.randInt(4, 6)
    local pts = {}

    -- First point: left edge, near vertical center
    pts[1] = {
        cx + gen.randRange(2, 8),
        cy + CELL_H * 0.5 + gen.randRange(-6, 6),
    }

    -- Last point: right edge, near vertical center
    pts[nPts] = {
        cx + CELL_W - gen.randRange(2, 8),
        cy + CELL_H * 0.5 + gen.randRange(-6, 6),
    }

    -- Interior points: spread across cell with perlin-biased y
    for i = 2, nPts - 1 do
        local t = (i - 1) / (nPts - 1)
        local px = cx + CELL_W * t + gen.randRange(-5, 5)
        local noiseY = gen.perlin(idx * 3.7 + i * 1.3, t * 4.0)
        local py = cy + CELL_H * 0.5 + noiseY * CELL_H * 0.35 + gen.randRange(-4, 4)
        pts[i] = {px, py}
    end

    local strokes = {}
    strokes[1] = gen.smooth(gen.polyline(pts), 3)

    -- ~20% chance of a second flourish stroke
    if gen.rand() < 0.20 then
        local fPts = {}
        local anchor = pts[gen.randInt(2, math.max(2, nPts - 1))]
        local dir = gen.rand() < 0.5 and -1 or 1
        fPts[1] = {anchor[1] + gen.randRange(-3, 3), anchor[2]}
        fPts[2] = {anchor[1] + gen.randRange(-6, 6), anchor[2] + dir * gen.randRange(10, 22)}
        fPts[3] = {anchor[1] + gen.randRange(4, 12), anchor[2] + dir * gen.randRange(5, 18)}
        strokes[2] = gen.smooth(gen.polyline(fPts), 2)
    end

    -- ~15% chance of a wobbly dot modifier above or below
    if gen.rand() < 0.15 then
        local mx = cx + gen.randRange(CELL_W * 0.3, CELL_W * 0.7)
        local above = gen.rand() < 0.5
        local my = above
            and (cy + gen.randRange(2, 10))
            or  (cy + CELL_H - gen.randRange(2, 10))
        strokes[#strokes + 1] = wobblyDot(mx, my, gen.randRange(1.5, 3.5))
    end

    return strokes, pts[1]
end

-- Draw a stroke with ghost traces behind it.
local function drawWithGhosts(stroke)
    -- Ghost passes jitter a coarse resample and smooth it again, so each
    -- reads as a separate wobbly retrace rather than fuzz.
    local ghosts = {
        {jitter = 2, opacity = 0.5, sw = 0.9},
        {jitter = 3, opacity = 0.38, sw = 0.8},
        {jitter = 4, opacity = 0.28, sw = 0.8},
        {jitter = 5, opacity = 0.2, sw = 0.7},
        {jitter = 6, opacity = 0.14, sw = 0.7},
    }
    for _, g in ipairs(ghosts) do
        local ghostShape = gen.smooth(gen.jitter(gen.resample(stroke, 8), g.jitter), 3)
        gen.draw(c, ghostShape, {
            stroke = ink,
            strokeWidth = g.sw,
            opacity = g.opacity,
            strokeLinecap = "round",
        })
    end

    -- Main stroke
    local style = {
        stroke = ink,
        strokeWidth = 1.8,
        opacity = 0.9,
        strokeLinecap = "round",
    }
    if stroke.type == "polygon" then
        style.fill = ink
        style.fillOpacity = 0.7
        style.strokeWidth = 0.6
    end
    gen.draw(c, stroke, style)
end

-- Generate and draw all characters
local idx = 0
for row = 0, ROWS - 1 do
    for col = 0, COLS - 1 do
        idx = idx + 1
        local cx = MARGIN_X + col * CELL_W
        local cy = MARGIN_Y + row * CELL_H + gen.randRange(-2, 2)
        local strokes, startPt = makeGlyph(cx, cy, idx)

        -- ~12% chance of a splatter at the stroke start, varying intensity
        if gen.rand() < 0.12 then
            drawSplatter(startPt[1], startPt[2], gen.rand())
        end

        for _, stroke in ipairs(strokes) do
            drawWithGhosts(stroke)
        end
    end
end

return c
