-- topographic.lua — Topographic Map
-- Contour lines from layered Perlin noise, colored by elevation,
-- with stippled land regions and smooth contour paths.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0b1a2b"))
gen.seed(42)
gen.noiseSeed(42)

-- Elevation function: layered fbm noise
local function elevation(x, y)
    -- main terrain
    local e = gen.fbm(x * 0.003, y * 0.003, 5, 2.0, 0.5)
    -- add a ridge
    e = e + 0.3 * gen.perlin(x * 0.008 + 5, y * 0.006)
    -- normalize roughly to [0, 1]
    return gen.clamp(e * 0.5 + 0.5, 0, 1)
end

-- Color by elevation: deep water → shallow → sand → grass → rock → snow
local function elevationColor(e)
    if e < 0.30 then
        -- deep water
        return gen.hsv(0.6, 0.7, gen.lerp(0.15, 0.3, e / 0.30))
    elseif e < 0.40 then
        -- shallow water
        local t = (e - 0.30) / 0.10
        return gen.hsv(0.55, gen.lerp(0.7, 0.5, t), gen.lerp(0.3, 0.45, t))
    elseif e < 0.45 then
        -- sand/beach
        local t = (e - 0.40) / 0.05
        return gen.hsv(0.12, gen.lerp(0.4, 0.5, t), gen.lerp(0.55, 0.5, t))
    elseif e < 0.60 then
        -- lowland green
        local t = (e - 0.45) / 0.15
        return gen.hsv(gen.lerp(0.28, 0.33, t), 0.55, gen.lerp(0.35, 0.45, t))
    elseif e < 0.75 then
        -- highland
        local t = (e - 0.60) / 0.15
        return gen.hsv(gen.lerp(0.33, 0.08, t), gen.lerp(0.55, 0.3, t), gen.lerp(0.45, 0.4, t))
    else
        -- rock/snow
        local t = (e - 0.75) / 0.25
        return gen.hsv(0.08, gen.lerp(0.2, 0.05, t), gen.lerp(0.45, 0.7, t))
    end
end

-- === Layer 1: Stippled terrain fill ===
-- Sample a grid and place colored dots based on elevation
local dotSpacing = 6
for py = 0, H - 1, dotSpacing do
    for px = 0, W - 1, dotSpacing do
        local x = px + gen.randRange(-2, 2)
        local y = py + gen.randRange(-2, 2)
        local e = elevation(x, y)
        local col = elevationColor(e)
        local size = gen.lerp(1.0, 2.0, e)
        gen.draw(c, gen.circle({x, y}, size), {
            fill = col,
            opacity = gen.lerp(0.3, 0.6, e),
        })
    end
end

-- === Layer 2: Contour lines ===
-- March a grid and trace contour segments using marching squares
local step = 4
local levels = {0.30, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85}

-- Precompute elevation grid
local gridCols = math.floor(W / step) + 1
local gridRows = math.floor(H / step) + 1
local elev = {}
for gy = 0, gridRows - 1 do
    elev[gy] = {}
    for gx = 0, gridCols - 1 do
        elev[gy][gx] = elevation(gx * step, gy * step)
    end
end

for _, level in ipairs(levels) do
    local col = elevationColor(level)
    local isWaterLine = level <= 0.40
    local lineWidth = isWaterLine and 0.6 or 0.4
    local opacity = isWaterLine and 0.7 or 0.5

    -- major contour lines (every other) are thicker
    local idx = 0
    for li, lv in ipairs(levels) do
        if lv == level then idx = li break end
    end
    if idx % 3 == 0 then
        lineWidth = lineWidth + 0.4
        opacity = opacity + 0.15
    end

    -- Simple marching squares: find line segments where the contour crosses grid cells
    for gy = 0, gridRows - 2 do
        for gx = 0, gridCols - 2 do
            local tl = elev[gy][gx]
            local tr = elev[gy][gx + 1]
            local bl = elev[gy + 1][gx]
            local br = elev[gy + 1][gx + 1]

            local x0, y0 = gx * step, gy * step

            -- classify corners
            local config = 0
            if tl >= level then config = config + 8 end
            if tr >= level then config = config + 4 end
            if br >= level then config = config + 2 end
            if bl >= level then config = config + 1 end

            -- skip full/empty cells
            if config ~= 0 and config ~= 15 then
                -- interpolation helpers
                local function lerpEdge(v0, v1)
                    if math.abs(v1 - v0) < 1e-10 then return 0.5 end
                    return (level - v0) / (v1 - v0)
                end

                -- edge midpoints (interpolated)
                local top = {x0 + lerpEdge(tl, tr) * step, y0}
                local bottom = {x0 + lerpEdge(bl, br) * step, y0 + step}
                local left = {x0, y0 + lerpEdge(tl, bl) * step}
                local right = {x0 + step, y0 + lerpEdge(tr, br) * step}

                -- draw segments based on marching squares config
                local segs = {}
                if config == 1 or config == 14 then
                    segs = {{left, bottom}}
                elseif config == 2 or config == 13 then
                    segs = {{bottom, right}}
                elseif config == 3 or config == 12 then
                    segs = {{left, right}}
                elseif config == 4 or config == 11 then
                    segs = {{top, right}}
                elseif config == 5 then
                    segs = {{left, top}, {bottom, right}}
                elseif config == 6 or config == 9 then
                    segs = {{top, bottom}}
                elseif config == 7 or config == 8 then
                    segs = {{left, top}}
                elseif config == 10 then
                    segs = {{top, right}, {left, bottom}}
                end

                for _, seg in ipairs(segs) do
                    gen.draw(c, gen.line(seg[1], seg[2]), {
                        stroke = col,
                        strokeWidth = lineWidth,
                        opacity = opacity,
                    })
                end
            end
        end
    end
end

-- === Layer 3: Elevation labels (small circles at peaks) ===
-- Find local maxima and mark them
for py = 40, H - 40, 80 do
    for px = 40, W - 40, 80 do
        local e = elevation(px, py)
        -- check if this is a local peak
        local isPeak = true
        for dy = -20, 20, 20 do
            for dx = -20, 20, 20 do
                if not (dx == 0 and dy == 0) then
                    if elevation(px + dx, py + dy) > e then
                        isPeak = false
                    end
                end
            end
        end
        if isPeak and e > 0.60 then
            -- peak marker: concentric rings
            gen.draw(c, gen.circle({px, py}, 5), {
                stroke = gen.hsv(0.08, 0.1, 0.8),
                strokeWidth = 0.5,
                fill = "none",
                opacity = 0.5,
            })
            gen.draw(c, gen.circle({px, py}, 1.5), {
                fill = gen.hsv(0.08, 0.1, 0.9),
                opacity = 0.7,
            })
        end
    end
end

return c
