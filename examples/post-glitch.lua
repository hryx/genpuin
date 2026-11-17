-- A red sun over black bars, melted, torn and channel split. Shows gen.post
-- with pixelSort, tear and channelShift.

local W, H = 800, 800
local yellow = {1, 0.84, 0.04, 1}
local red = {0.86, 0.06, 0.05, 1}
local hot = {1, 0.32, 0.08, 1}
local ink = {0.05, 0.02, 0.03, 1}

gen.seed(23)
gen.noiseSeed(23)

local c = gen.canvas(W, H)
gen.background(c, yellow)

local sun = {430, 360}
for i = 14, 1, -1 do
    local col = gen.lerpColor(red, hot, i / 14)
    gen.draw(c, gen.circle(sun, 120 + i * 16), {fill = col, opacity = 0.18})
end
gen.draw(c, gen.circle(sun, 240), {fill = red})
for r = 60, 230, 14 do
    gen.draw(c, gen.circle(sun, r), {stroke = ink, strokeWidth = 1 + r / 90})
end

local y = H
local t = 12
while y > 380 and t > 0.6 do
    gen.draw(c, gen.rect(0, y - t, W, t), {fill = ink})
    y = y - t - t * 0.9
    t = t * 0.96
end

for _ = 1, 70 do
    local x, by = gen.randRange(0, W), gen.randRange(0, H)
    local w, h = gen.randRange(4, 70), gen.randRange(2, 10)
    gen.draw(c, gen.rect(x, by, w, h), {fill = gen.pick({ink, red, hot, yellow})})
end

local mask = gen.field(120, 120)
mask:fill(function(x, y)
    return gen.fbm(x * 0.045, y * 0.03, 4) * 0.5 + 0.5 + (y / 120 - 0.5) * 0.25
end)

gen.post(c, "pixelSort", {
    direction = "y", mask = mask, maskThreshold = 0.56,
    maxLength = 260, jitter = 0.7, chance = 0.9,
})
gen.post(c, "pixelSort", {
    angle = 180, key = "luma", lo = 0.15, hi = 0.75, sortBy = "hue",
    maxLength = 90, chance = 0.25, region = {0, 300, W, 140},
})
gen.post(c, "tear", {
    minHeight = 2, maxHeight = 24, minShift = 10, maxShift = 140,
    chance = 0.35, region = {0, 180, W, 420},
})
gen.post(c, "blockRepeat", {count = 18, minSize = 16, maxSize = 96, grid = 16, mode = "smearY"})
gen.post(c, "channelShift", {r = {7, 0}, b = {-5, 2}})
gen.post(c, "grain", {amount = 0.07, size = 1})
gen.post(c, "scanlines", {period = 3, width = 1, strength = 0.12})

return c
