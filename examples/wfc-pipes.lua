-- Wave function collapse plumbing, sparse at the top and heavy at the floor.
-- Shows gen.wfc with symmetry classes and a weight map, and gen.wfcDraw.

local W, H = 800, 800
local CELL = 20
local COLS, ROWS = 38, 38
local OX, OY = (W - COLS * CELL) / 2, (H - ROWS * CELL) / 2

gen.seed(7)
gen.noiseSeed(7)

local c = gen.canvas(W, H)
gen.background(c, gen.hex("#14121c"))

-- Sockets: 0 open air, 1 thin wire, 2 thick pipe.
local tiles = {
    {name = "air",     edges = {0, 0, 0, 0}, weight = 1},
    {name = "wire",    edges = {1, 0, 1, 0}, symmetry = "I", weight = 2},
    {name = "wbend",   edges = {1, 1, 0, 0}, symmetry = "L", weight = 2},
    {name = "wtee",    edges = {1, 1, 1, 0}, symmetry = "T", weight = 0.6},
    {name = "wcross",  edges = {1, 1, 1, 1}, weight = 0.3},
    {name = "node",    edges = {1, 0, 0, 0}, symmetry = "T", weight = 0.4},
    {name = "pipe",    edges = {2, 0, 2, 0}, symmetry = "I", weight = 2},
    {name = "pbend",   edges = {2, 2, 0, 0}, symmetry = "L", weight = 2},
    {name = "ptee",    edges = {2, 2, 2, 0}, symmetry = "T", weight = 0.5},
    {name = "cap",     edges = {2, 0, 0, 0}, symmetry = "T", weight = 0.2},
    {name = "under",   edges = {2, 1, 2, 1}, symmetry = "I", weight = 0.8},
    {name = "reducer", edges = {2, 0, 1, 0}, symmetry = "T", weight = 0.5},
}

-- Density steering. Air dominates the top and thins out toward the bottom,
-- thick pipe does the opposite. Noise keeps the boundary ragged.
local FW, FH = 48, 48
local airMap = gen.field(FW, FH)
local heavyMap = gen.field(FW, FH)
local wireMap = gen.field(FW, FH)
airMap:fill(function(x, y)
    local t = y / (FH - 1)
    local n = gen.fbm(x * 0.09, y * 0.09, 3)
    return 0.12 + 30 * math.max(0, 1 - t * 1.3 + n * 0.45) ^ 2.4
end)
heavyMap:fill(function(x, y)
    local t = y / (FH - 1)
    local n = gen.fbm(x * 0.07 + 11, y * 0.07, 3)
    return 0.02 + 3.2 * math.max(0, t - 0.25 + n * 0.3) ^ 1.6
end)
wireMap:fill(function(x, y)
    local t = y / (FH - 1)
    return 0.5 + 1.2 * math.sin(math.pi * t)
end)

-- Pin an air border so every pipe stays inside the frame.
local border = {}
for i = 1, COLS do
    border[#border + 1] = {x = i, y = 1, tile = "air"}
    border[#border + 1] = {x = i, y = ROWS, tile = "air"}
end
for j = 2, ROWS - 1 do
    border[#border + 1] = {x = 1, y = j, tile = "air"}
    border[#border + 1] = {x = COLS, y = j, tile = "air"}
end

local result = gen.wfc({
    w = COLS, h = ROWS, tiles = tiles, constraints = border,
    weightMap = {
        air = airMap,
        pipe = heavyMap, pbend = heavyMap, ptee = heavyMap, under = heavyMap, cap = heavyMap,
        wire = wireMap, wbend = wireMap, wtee = wireMap,
    },
})

-- Tile geometry in local units: the cell spans -1..1, north is v = -1.
-- Each primitive is {kind, layer, ...}. Layer 1 is wire, 2 is pipe.
local geometry = {
    wire    = {{"line", 1, 0, -1, 0, 1}},
    wbend   = {{"arc", 1, 1, -1, math.pi / 2, math.pi}},
    wtee    = {{"line", 1, 0, -1, 0, 1}, {"line", 1, 0, 0, 1, 0}, {"dot", 1, 0, 0, 0.32}},
    wcross  = {{"line", 1, 0, -1, 0, 1}, {"line", 1, -1, 0, 1, 0}, {"dot", 1, 0, 0, 0.38}},
    node    = {{"line", 1, 0, -1, 0, -0.3}, {"ring", 1, 0, 0, 0.42}},
    pipe    = {{"line", 2, 0, -1, 0, 1}},
    pbend   = {{"arc", 2, 1, -1, math.pi / 2, math.pi}},
    ptee    = {{"line", 2, 0, -1, 0, 1}, {"line", 2, 0, 0, 1, 0}},
    cap     = {{"line", 2, 0, -1, 0, 0}, {"dot", 2, 0, 0, 0.62}},
    under   = {{"line", 1, -1, 0, 1, 0}, {"line", 2, 0, -1, 0, 1}, {"band", 2, 0, -0.35, 0, 0.35}},
    reducer = {{"line", 1, 0, 0, 0, 1}, {"line", 2, 0, -1, 0, 0.05}, {"dot", 2, 0, 0.05, 0.5}},
}

-- Strokes that end on the cell edge run a hair past it so neighbouring
-- cells overlap instead of leaving an antialiased seam.
local function bleed(x)
    if x == 1 then return 1.04 elseif x == -1 then return -1.04 end
    return x
end

local function place(p, cx, cy, half, rot, flip)
    local u, v = p[1], p[2]
    if flip then u = -u end
    for _ = 1, rot do u, v = -v, u end
    return {cx + u * half, cy + v * half}
end

-- Collect primitives in pixel space first so each layer can be drawn in
-- passes: dark casing, body, then highlight.
local prims = {{}, {}}
gen.wfcDraw(c, result, {
    size = CELL, x = OX, y = OY,
    draw = function(tile, x, y, size, rot, flip)
        local half = size / 2
        for _, g in ipairs(geometry[tile] or {}) do
            local kind, layer = g[1], g[2]
            local p = {kind = kind, y = y}
            if kind == "line" or kind == "band" then
                p.a = place({bleed(g[3]), bleed(g[4])}, x, y, half, rot, flip)
                p.b = place({bleed(g[5]), bleed(g[6])}, x, y, half, rot, flip)
            elseif kind == "arc" then
                local arc = gen.arc({x + g[3] * half, y + g[4] * half}, half, g[5] - 0.04, g[6] + 0.04)
                p.arc = gen.rotateAround(arc, rot * math.pi / 2, {x, y})
            else
                p.center = place({g[3], g[4]}, x, y, half, rot, flip)
                p.r = g[5] * half
            end
            table.insert(prims[layer], p)
        end
    end,
})

local function shapeOf(p)
    if p.kind == "line" or p.kind == "band" then return gen.line(p.a, p.b) end
    if p.kind == "arc" then return p.arc end
    return gen.circle(p.center, p.r)
end

-- Colour runs from a cold violet up top to molten orange at the floor.
local top, mid, low = gen.hex("#6c6fd1"), gen.hex("#e0568a"), gen.hex("#ffb347")
local function tint(y)
    local t = gen.clamp((y - OY) / (ROWS * CELL), 0, 1)
    if t < 0.5 then return gen.lerpColor(top, mid, t * 2) end
    return gen.lerpColor(mid, low, (t - 0.5) * 2)
end

local casing = gen.hex("#0b0a10")
local widths = {
    {case = 7, body = 3.2, glint = 1.1},
    {case = 15, body = 10, glint = 3},
}

for layer = 1, 2 do
    local wd = widths[layer]
    for pass = 1, 3 do
        for _, p in ipairs(prims[layer]) do
            local col = tint(p.y)
            local stroke, width, cap
            if pass == 1 then
                stroke, width = casing, wd.case
            elseif pass == 2 then
                stroke, width = col, wd.body
            else
                stroke, width = gen.lighten(col, 0.35), wd.glint
            end
            if p.kind == "line" or p.kind == "arc" then
                gen.draw(c, shapeOf(p), {stroke = stroke, strokeWidth = width, strokeLinecap = "butt"})
            elseif p.kind == "band" then
                -- Collar where the pipe passes over a wire.
                if pass == 1 then
                    gen.draw(c, shapeOf(p), {stroke = casing, strokeWidth = wd.case + 4})
                elseif pass == 2 then
                    gen.draw(c, shapeOf(p), {stroke = gen.darken(col, 0.25), strokeWidth = wd.body + 4})
                end
            elseif p.kind == "ring" then
                if pass == 1 then
                    gen.draw(c, shapeOf(p), {fill = casing, stroke = casing, strokeWidth = 4})
                elseif pass == 2 then
                    gen.draw(c, shapeOf(p), {stroke = col, strokeWidth = 2.2})
                else
                    gen.draw(c, gen.circle(p.center, p.r * 0.35), {fill = gen.lighten(col, 0.5)})
                end
            else
                if pass == 1 then
                    gen.draw(c, gen.circle(p.center, p.r + (wd.case - wd.body) / 2), {fill = casing})
                elseif pass == 2 then
                    gen.draw(c, shapeOf(p), {fill = col})
                else
                    gen.draw(c, gen.circle(p.center, p.r * 0.35), {fill = gen.lighten(col, 0.4)})
                end
            end
        end
    end
end

return c
