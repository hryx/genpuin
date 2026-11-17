-- Op art from polygon booleans: rings xor a turning star, a disc showing only
-- where it meets the ink. Shows gen.clip and gen.offset.

local W, H = 800, 800
gen.canvas(W, H)
gen.background(gen.hex("#f1ead8"))
gen.seed(7)

local cx, cy = W / 2, H / 2

-- Concentric circles read with the even-odd rule become rings.
local circles = {}
for i = 1, 14 do circles[i] = gen.circle({cx, cy}, i * 26) end
local ringShape = gen.clip(circles, nil, "union", {rule = "evenodd"})

local star = {}
local n = 24
for i = 0, n - 1 do
    local r = (i % 2 == 0) and 360 or 120
    local t = i / n * 2 * math.pi + r * 0.0025
    star[#star + 1] = {cx + r * math.cos(t), cy + r * math.sin(t)}
end
local starShape = gen.polygon(star)

local art = gen.clip(ringShape, starShape, "xor")

local frame = gen.rect(60, 60, W - 120, H - 120, 36)
art = gen.clip(art, frame, "intersect")
gen.draw(art, {fill = gen.hex("#1d1b26")})

local disc = gen.circle({cx + 120, cy - 110}, 150)
local onInk = gen.clip(disc, art, "intersect")
local onPaper = gen.clip(gen.clip(disc, frame, "intersect"), art, "difference")
gen.draw(onPaper, {fill = gen.hex("#d9a441")})
gen.draw(onInk, {fill = gen.hex("#c8372d")})

local all = gen.clip(art, gen.clip(disc, frame, "intersect"), "union")
gen.draw(gen.offset(all, 8, {resolution = 1.5}), {stroke = gen.hex("#1d1b26"), strokeWidth = 1.2})
