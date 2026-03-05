-- test-blend.lua — Overlapping transparent shape verification
-- Renders examples/test-blend.lua to PPM and checks that alpha compositing
-- produces correct color buildup in overlap regions (Venn diagram style).

local T = require("test.testkit")

local check = T.check
local gray = T.gray
local rgb = T.rgb

------------------------------------------------------------
-- Render
------------------------------------------------------------
print("Rendering test-blend.ppm...")
T.render("examples/test-blend.lua", "out/test/test-blend.ppm")

local pixels, W, H = T.readPpm("out/test/test-blend.ppm")
print(string.format("Loaded %dx%d PPM\n", W, H))

-- Helper: check a gray value is within tolerance of expected
local function nearGray(name, x, y, expected, tol)
    tol = tol or 5
    local v = gray(pixels, x, y)
    check(name, math.abs(v - expected) <= tol,
        string.format("(%d,%d) gray=%d, expected %d±%d", x, y, v, expected, tol))
end

-- Helper: check RGB values are within tolerance
local function nearRgb(name, x, y, er, eg, eb, tol)
    tol = tol or 5
    local r, g, b = rgb(pixels, x, y)
    local ok = math.abs(r - er) <= tol and math.abs(g - eg) <= tol and math.abs(b - eb) <= tol
    check(name, ok,
        string.format("(%d,%d) rgb=(%d,%d,%d), expected (%d,%d,%d)±%d",
            x, y, r, g, b, er, eg, eb, tol))
end

------------------------------------------------------------
-- Test 1: Black circles, opacity 0.5
-- Circle A: center (60,60), r=40
-- Circle B: center (100,60), r=40
--
-- Compositing math (black on white, α=0.5):
--   Single shape: 0*0.5 + 255*0.5 = 128
--   Overlap (second shape on top of first result):
--     0*0.5 + 128*0.5 = 64
------------------------------------------------------------
print("Test 1: Black overlapping circles, opacity 0.5")

-- Background: far from both circles
nearGray("background is white", 10, 10, 255)

-- Circle A only: x=30, y=60 (well inside A, far from B)
nearGray("A-only region", 30, 60, 128)

-- Circle B only: x=130, y=60 (well inside B, far from A)
nearGray("B-only region", 130, 60, 128)

-- Overlap region: x=80, y=60 (center between both circles)
nearGray("overlap region darker", 80, 60, 64)

-- Verify ordering: overlap < single < background
local vA = gray(pixels, 30, 60)
local vOverlap = gray(pixels, 80, 60)
local vBg = gray(pixels, 10, 10)
check("monotonic darkness: overlap < single < bg",
    vOverlap < vA and vA < vBg,
    string.format("overlap=%d, single=%d, bg=%d", vOverlap, vA, vBg))

------------------------------------------------------------
-- Test 2: Colored circles (red + blue), opacity 0.5
-- Red circle: center (60,150), r=35
-- Blue circle: center (100,150), r=35
--
-- Compositing math:
--   Red on white (α=0.5):
--     R: 255*0.5 + 255*0.5 = 255
--     G: 0*0.5 + 255*0.5 = 128
--     B: 0*0.5 + 255*0.5 = 128
--     → (255, 128, 128)
--
--   Blue on white (α=0.5):
--     R: 0*0.5 + 255*0.5 = 128
--     G: 0*0.5 + 255*0.5 = 128
--     B: 255*0.5 + 255*0.5 = 255
--     → (128, 128, 255)
--
--   Blue on top of red result (α=0.5):
--     R: 0*0.5 + 255*0.5 = 128
--     G: 0*0.5 + 128*0.5 = 64
--     B: 255*0.5 + 128*0.5 = 192
--     → (128, 64, 192) — purple!
------------------------------------------------------------
print("\nTest 2: Red + blue overlapping circles, opacity 0.5")

-- Red-only region: x=35, y=150
nearRgb("red-only region", 35, 150, 255, 128, 128)

-- Blue-only region: x=125, y=150
nearRgb("blue-only region", 125, 150, 128, 128, 255)

-- Overlap region: x=80, y=150 — should be purple
nearRgb("overlap is purple", 80, 150, 128, 64, 192)

-- Verify: overlap R < red-only R (blue darkens the red channel)
local rRed = rgb(pixels, 35, 150)
local rOverlap = rgb(pixels, 80, 150)
check("red channel darkens in overlap",
    rOverlap < rRed,
    string.format("overlap R=%d, red-only R=%d", rOverlap, rRed))

------------------------------------------------------------
-- Summary
------------------------------------------------------------
T.summary()
