-- A black eclipse in a noise sky, bloomed and crushed to four colors with
-- blue noise and Bayer screens. Shows gen.post with bloom and dither.

local W, H = 800, 800
local ink = {0.04, 0.02, 0.03, 1}
local red = {0.82, 0.05, 0.06, 1}
local hot = {1, 0.42, 0.1, 1}
local yellow = {1, 0.88, 0.1, 1}

gen.seed(5)
gen.noiseSeed(5)

gen.canvas(W, H)
gen.background(ink)

local n = 200
local sky = gen.field(n, n)
sky:fill(function(x, y)
    local dx, dy = x / n - 0.42, y / n - 0.4
    local d = math.sqrt(dx * dx + dy * dy)
    return 0.9 - d * 1.8 + gen.fbm(x * 0.02, y * 0.035, 5) * 0.55
end)
gen.draw(gen.image(sky, 0, 0, W, H, {palette = {ink, red, hot, yellow}}))

for i = 1, 26 do
    local x = gen.randRange(60, 740)
    local pts = {}
    for k = 0, 12 do
        local t = k / 12
        pts[#pts + 1] = {x + gen.perlin(i, t * 3) * 120, 800 - t * gen.randRange(300, 760)}
    end
    gen.draw(gen.spline(pts), {stroke = gen.pick({yellow, hot, ink}), strokeWidth = gen.randRange(2, 14), opacity = 0.45})
end

local sun = {336, 320}
gen.draw(gen.circle(sun, 210), {fill = yellow, opacity = 0.5})
gen.draw(gen.circle(sun, 176), {fill = {1, 1, 0.85, 1}})
gen.draw(gen.circle({356, 330}, 168), {fill = ink})

gen.post.blur({radius = 3})
gen.post.bloom({threshold = 0.7, radius = 40, strength = 0.6})

gen.post.levels({black = 0.08, gamma = 0.7})

local palette = {ink, red, hot, yellow}
gen.post.dither({method = "blue", palette = palette, cell = 2})
gen.post.dither({method = "bayer", matrix = 4, palette = palette, cell = 6, region = {600, 0, 200, H}})

gen.draw(gen.rect(596, 0, 4, H), {fill = yellow})
