-- Evenly spaced streamlines through a Perlin flow field, weighted by length.
-- Shows gen.noiseField, gen.flowField and gen.trace.

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#efe7d6"))
gen.seed(11)
gen.noiseSeed(11)

local forward = gen.noiseField(0.0022)
local backward = gen.flowField(function(x, y)
    return forward.sample(x, y) + math.pi
end)

-- Jobard and Lefer evenly spaced streamlines: a line stops when it comes
-- within gap of another line.
local gap, cell = 7, 7
local cols, rows = math.ceil(W / cell), math.ceil(H / cell)
local taken = {}

local function free(p, own)
    if p[1] < 20 or p[1] > W - 20 or p[2] < 20 or p[2] > H - 20 then return false end
    local cx, cy = math.floor(p[1] / cell), math.floor(p[2] / cell)
    for y = cy - 1, cy + 1 do
        for x = cx - 1, cx + 1 do
            local q = taken[y * cols + x]
            if q and q.line ~= own and gen.dist(p, q) < gap then return false end
        end
    end
    return true
end

local function grow(field, start, own)
    local out = {}
    for _, p in ipairs(gen.trace(field, start, 260, 1.5).points) do
        if not free(p, own) then break end
        out[#out + 1] = p
    end
    return out
end

local palette = {gen.hex("#d99a3d"), gen.hex("#b5442c"), gen.hex("#2f5d62"), gen.hex("#1d2a3a")}
local lines = {}

for i, seed in ipairs(gen.poissonDisk({20, 20, W - 40, H - 40}, 12)) do
    if free(seed, i) then
        local back = grow(backward, seed, i)
        local pts = {}
        for k = #back, 2, -1 do pts[#pts + 1] = back[k] end
        for _, p in ipairs(grow(forward, seed, i)) do pts[#pts + 1] = p end
        if #pts > 30 then
            for _, p in ipairs(pts) do
                taken[math.floor(p[2] / cell) * cols + math.floor(p[1] / cell)] = {p[1], p[2], line = i}
            end
            lines[#lines + 1] = pts
        end
    end
end

for _, pts in ipairs(lines) do
    local t = gen.clamp(#pts / 360, 0, 1)
    local mid = pts[math.floor(#pts / 2) + 1]
    local tone = gen.perlin(mid[1] * 0.003, mid[2] * 0.003) * 2 + 0.5
    local band = gen.clamp(math.floor(tone * 4) + 1, 1, 4)
    gen.draw(c, gen.polyline(pts), {
        stroke = palette[band], fill = "none",
        strokeWidth = gen.lerp(0.9, 3.6, t * t), strokeLinecap = "round",
    })
end

return c
