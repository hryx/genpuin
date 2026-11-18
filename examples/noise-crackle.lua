-- A celadon bowl seen from above, its glaze crazed with dark and golden
-- cracks. Shows gen.worley and gen.post.grain.

gen.seed(3)
gen.noiseSeed(3)
local W, H = 800, 800
gen.canvas(W, H)
gen.background(gen.hex("#2e3540"))

local cx, cy, R, well, depth = 400, 400, 320, 110, 170
gen.draw(gen.circle({cx + 18, cy + 26}, R), {fill = gen.hex("#151a20")})
gen.post.blur({radius = 18})

local function height(r)
    if r < well then return 0 end
    local t = (r - well) / (R - well)
    return depth * t * t
end

-- Cracks are laid out by distance along the wall, so they bunch up toward
-- the steep rim when seen from above.
local arc, s = {}, 0
for r = 0, R + 1 do
    arc[r] = s
    local dh = height(r + 1) - height(r)
    s = s + math.sqrt(1 + dh * dh)
end

local glaze, crack = gen.field(W, H, -1), gen.field(W, H, 0)
local lx, ly, lz = -0.45, -0.55, 0.7
local hx, hy, hz = lx, ly, lz + 1
local hl = math.sqrt(hx * hx + hy * hy + hz * hz)
hx, hy, hz = hx / hl, hy / hl, hz / hl
for y = 0, H - 1 do
    for x = 0, W - 1 do
        local dx, dy = x + 0.5 - cx, y + 0.5 - cy
        local r = math.sqrt(dx * dx + dy * dy)
        if r < R + 1 then
            local slope = (height(r + 0.5) - height(r - 0.5)) / math.max(r, 1e-6)
            local nx, ny = -dx * slope, -dy * slope
            local len = math.sqrt(nx * nx + ny * ny + 1)
            local diffuse = (nx * lx + ny * ly + lz) / len
            local spec = math.max((nx * hx + ny * hy + hz) / len, 0)
            for _ = 1, 6 do spec = spec * spec end
            glaze:set(x, y, math.max(0.75 * diffuse + 0.25 * spec, 0.01))
            local i = math.floor(r)
            local sr = arc[i] + (arc[i + 1] - arc[i]) * (r - i)
            local k = sr / math.max(r, 1e-6)
            local u, v = cx + dx * k, cy + dy * k
            u, v = u + 14 * gen.perlin(u * 0.01, v * 0.01), v + 14 * gen.perlin(u * 0.01 + 7, v * 0.01)
            local fade = gen.clamp(0.5 + 1.2 * gen.perlin(u * 0.006 + 3, v * 0.006), 0, 1)
            local f1, f2 = gen.worley(u * 0.016, v * 0.016)
            local g1, g2 = gen.worley(u * 0.05 + 31, v * 0.05 + 17)
            local big = 1 - math.min((f2 - f1) / 0.05, 1)
            local fine = 1 - math.min((g2 - g1) / 0.07, 1)
            crack:set(x, y, math.max(big * (0.7 + 0.3 * fade), fine * 0.5))
        end
    end
end

local jade = gen.hex("#5f8a73")
gen.draw(gen.image(glaze, 0, 0, W, H, {range = {-1, 1}, palette = {
    {0, gen.withAlpha(jade, 0)},
    {0.49, gen.withAlpha(jade, 0)},
    {0.5, gen.hex("#3f6656")},
    {0.75, jade},
    {0.87, gen.hex("#a9c8b2")},
    {1, gen.hex("#f2f5ec")},
}}))
local iron = gen.hex("#2a1d17")
gen.draw(gen.image(crack, 0, 0, W, H, {range = {0, 1}, palette = {
    {0, gen.withAlpha(iron, 0)},
    {0.2, gen.withAlpha(gen.hex("#b88a3e"), 0)},
    {0.5, gen.withAlpha(gen.hex("#b88a3e"), 0.8)},
    {0.7, gen.withAlpha(iron, 0.5)},
    {1, iron},
}}))
gen.draw(gen.circle({cx, cy}, R - 3), {stroke = gen.hex("#6b4a35"), strokeWidth = 5, fill = "none", strokeOpacity = 0.7})
gen.post.grain({amount = 0.04})
