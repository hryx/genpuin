-- A concrete tower block at night whose lit windows melt down the facade.
-- Shows gen.post with pixelSort, tear and channelShift.

local W, H = 800, 800
gen.seed(21)
gen.noiseSeed(21)

gen.canvas(W, H)
gen.background(gen.hex("#05071a"))

local lit = {gen.hex("#ff2e97"), gen.hex("#ff8fd0"), gen.hex("#3fd2ff"), gen.hex("#e4f6ff"), gen.hex("#9a6bff")}
local dark = {gen.hex("#0a1029"), gen.hex("#121c44"), gen.hex("#0d1534")}

for _ = 1, 160 do
    gen.draw(gen.circle({gen.randRange(0, W), gen.randRange(0, 300)}, gen.randRange(0.6, 1.8)),
        {fill = gen.hex("#a9b8ff"), opacity = gen.randRange(0.4, 1)})
end

local x0, y0, cols, rows = 140, 90, 10, 19
local cw, ch = 52, 36
gen.draw(gen.rect(x0 - 24, y0 - 24, cols * cw + 48, H), {fill = gen.hex("#3a4c86")})
gen.draw(gen.rect(x0 - 24, y0 - 24, 12, H), {fill = gen.hex("#5a6fb0")})
for row = 0, rows - 1 do
    local y = y0 + row * ch
    for col = 0, cols - 1 do
        local glow = 0.35 + 0.3 * gen.fbm(col * 0.3, row * 0.25, 2)
        local color = gen.rand() < glow and gen.pick(lit) or gen.pick(dark)
        gen.draw(gen.rect(x0 + col * cw + 6, y + 6, cw - 12, ch - 14), {fill = color})
    end
    gen.draw(gen.rect(x0 - 24, y + ch - 7, cols * cw + 48, 5), {fill = gen.hex("#22305e")})
end
for col = 0, cols, 2 do
    gen.draw(gen.rect(x0 + col * cw - 3, y0 - 24, 6, H), {fill = gen.hex("#22305e")})
end
gen.draw(gen.rect(0, 770, W, 30), {fill = gen.hex("#03040c")})

local N = 200
local mask = gen.field(N, N)
mask:fill(function(x, y)
    local band = gen.fbm(x * 0.05 + 4.3, 4.2, 2)
    local start = 0.2 + (gen.fbm(x * 0.02, 9.1, 2) + 0.5) * 0.4
    return (band > -0.02 and y / N > start) and 1 or 0
end)

gen.post.pixelSort({direction = "y", mask = mask, reverse = true, maxLength = 320, jitter = 0.6})
gen.post.tear({minHeight = 4, maxHeight = 22, minShift = 12, maxShift = 60, chance = 0.08})
gen.post.channelShift({r = {3, 0}, b = {-3, 1}})
