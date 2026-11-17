-- A Game of Life soup run for 320 generations, every cell that ever lived
-- drawn as a dot colored by when it last lived. Shows gen.evolve and gen.life.

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0b0d17"))
gen.seed(5)

local N, size, gens = 160, 5, 320

local grid, last, count = {}, {}, {}
for y = 1, N do
    grid[y], last[y], count[y] = {}, {}, {}
    for x = 1, N do
        local d = gen.dist({x, y}, {N / 2, N / 2})
        grid[y][x] = (d < 48 and gen.rand() < 0.35) and 1 or 0
        last[y][x], count[y][x] = 0, 0
    end
end

for g = 1, gens do
    grid = gen.evolve(grid, gen.life, {wrap = false})
    for y = 1, N do
        for x = 1, N do
            if grid[y][x] == 1 then
                last[y][x] = g
                count[y][x] = count[y][x] + 1
            end
        end
    end
end

local stops = {gen.hex("#2b1d5c"), gen.hex("#7a2e7e"), gen.hex("#d4505a"), gen.hex("#f5a04a"), gen.hex("#fbe7a1")}
local function ramp(t)
    local s = t * (#stops - 1)
    local i = math.min(math.floor(s) + 1, #stops - 1)
    return gen.lerpColor(stops[i], stops[i + 1], s - (i - 1))
end

for y = 1, N do
    for x = 1, N do
        if last[y][x] > 0 then
            local t = last[y][x] / gens
            local r = gen.clamp(0.9 + math.sqrt(count[y][x]) * 0.35, 0.9, size * 0.5)
            local p = {(x - 0.5) * size, (y - 0.5) * size}
            if last[y][x] == gens then
                gen.draw(c, gen.circle(p, size * 0.5), {fill = gen.hex("#ffffff")})
            else
                gen.draw(c, gen.circle(p, r), {fill = ramp(t), opacity = gen.lerp(0.55, 1, t)})
            end
        end
    end
end

return c
