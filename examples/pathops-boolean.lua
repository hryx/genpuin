-- pathops-boolean.lua: op-art from polygon booleans.
-- Concentric rings xor a slowly turning star, a red disc that only shows
-- where it meets the ink, and a window cut out of the whole thing.

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#f1ead8"))
gen.seed(7)

local cx, cy = W / 2, H / 2

-- Concentric circles read with the even-odd rule become rings.
local circles = {}
for i = 1, 14 do circles[i] = gen.circle({cx, cy}, i * 26) end
local ringShape = gen.clip(circles, nil, "union", {rule = "evenodd"})

-- A twelve point star whose points twist as they go out.
local star = {}
local n = 24
for i = 0, n - 1 do
    local r = (i % 2 == 0) and 360 or 120
    local t = i / n * 2 * math.pi + r * 0.0025
    star[#star + 1] = {cx + r * math.cos(t), cy + r * math.sin(t)}
end
local starShape = gen.polygon(star)

local art = gen.clip(ringShape, starShape, "xor")

-- A window: the frame keeps everything outside a rounded rect.
local frame = gen.rect(60, 60, W - 120, H - 120, 36)
art = gen.clip(art, frame, "intersect")
gen.draw(c, art, {fill = gen.hex("#1d1b26")})

-- Red only where the disc lands on ink, ochre where it lands on paper.
local disc = gen.circle({cx + 120, cy - 110}, 150)
local onInk = gen.clip(disc, art, "intersect")
local onPaper = gen.clip(gen.clip(disc, frame, "intersect"), art, "difference")
gen.draw(c, onPaper, {fill = gen.hex("#d9a441")})
gen.draw(c, onInk, {fill = gen.hex("#c8372d")})

-- Thin outline of the union of everything, offset outward.
local all = gen.clip(art, gen.clip(disc, frame, "intersect"), "union")
gen.draw(c, gen.offset(all, 8, {resolution = 1.5}), {stroke = gen.hex("#1d1b26"), strokeWidth = 1.2})

return c
