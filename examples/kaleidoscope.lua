-- A rose window of shards mirrored around the circle in three turned, shrunken
-- rings. Shows gen.kaleidoscope, gen.rotateAround and gen.scaleAround.

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#101820"))
gen.seed(3)

local center = {W / 2, H / 2}
local n = 8
local half = math.pi / n
local palette = {
    gen.hex("#e8b04a"), gen.hex("#d0573e"), gen.hex("#3e8e8a"),
    gen.hex("#f2e6c9"), gen.hex("#7b3f61"),
}

local function polar(r, a)
    return {center[1] + r * math.cos(a), center[2] + r * math.sin(a)}
end

-- kaleidoscope mirrors each slice about its middle, so the motif only
-- needs to fill the first half slice. It sits in an outer band so each
-- shrunken copy reads as its own ring.
local motif = {}
for i = 1, 16 do
    local r = gen.randRange(200, 360)
    local a = gen.randRange(0, half)
    local dr, da = gen.randRange(16, 50), gen.randRange(0.05, 0.2)
    local pts = {
        polar(r - dr, a), polar(r, math.min(a + da, half)),
        polar(r + dr, a), polar(r, math.max(a - da, 0)),
    }
    motif[#motif + 1] = {shape = gen.polygon(pts), color = i}
end
for i = 1, 5 do
    local r = gen.randRange(190, 370)
    motif[#motif + 1] = {shape = gen.circle(polar(r, half), gen.randRange(4, 11)), color = i}
end

local rings = {
    {scale = 1.0, turn = 0},
    {scale = 0.56, turn = half},
    {scale = 0.31, turn = 0},
}

for k, ring in ipairs(rings) do
    for _, m in ipairs(motif) do
        local shape = gen.scaleAround(m.shape, ring.scale, ring.scale, center)
        shape = gen.rotateAround(shape, ring.turn, center)
        for _, s in ipairs(gen.kaleidoscope(n, center, {shape})) do
            gen.draw(c, s, {
                fill = palette[(m.color + k) % #palette + 1], fillOpacity = 0.92,
                stroke = gen.hex("#101820"), strokeWidth = 2 * ring.scale,
            })
        end
    end
end

return c
