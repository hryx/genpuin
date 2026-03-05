-- test-fills.lua — Filled shape anti-aliasing verification
-- Renders examples/test-fills.lua to PPM and checks edge cross-sections
-- for AA fringe pixels on polygon and ellipse edges.

local T = require("test.testkit")

local check = T.check
local gray = T.gray
local vSlice = T.vSlice
local hSlice = T.hSlice
local findIntermediates = T.findIntermediates
local fmtSlice = T.fmtSlice

------------------------------------------------------------
-- Render
------------------------------------------------------------
print("Rendering test-fills.ppm...")
T.render("examples/test-fills.lua", "out/test/test-fills.ppm")

local pixels, W, H = T.readPpm("out/test/test-fills.ppm")
print(string.format("Loaded %dx%d PPM\n", W, H))

------------------------------------------------------------
-- Test 1: Rotated square — right diagonal edge
-- Diamond with vertices at (50,20), (80,50), (50,80), (20,50).
-- Right edge goes from (50,20) to (80,50): at y=35 (midpoint of top-right
-- edge), x should be at 65. Sample horizontal slice there.
------------------------------------------------------------
print("Test 1: Rotated square — right diagonal edge at y=35")
local slice = hSlice(pixels, 35, 61, 69)
print("  H-section at y=35: " .. fmtSlice(slice))

-- Inside should be solid black
local v62 = gray(pixels, 62, 35)
check("inside pixel solid", v62 < 10,
    string.format("x=62 gray=%d, expected <10", v62))

-- Outside should be white
local v68 = gray(pixels, 68, 35)
check("outside pixel white", v68 > 250,
    string.format("x=68 gray=%d, expected >250", v68))

-- Edge should have AA fringe
local intermediates = findIntermediates(slice)
check("has AA fringe on diagonal edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 2: Rotated square — left diagonal edge
-- Left edge goes from (20,50) to (50,80): at y=65, x should be at 35.
------------------------------------------------------------
print("\nTest 2: Rotated square — left diagonal edge at y=65")
slice = hSlice(pixels, 65, 31, 39)
print("  H-section at y=65: " .. fmtSlice(slice))

local v31 = gray(pixels, 31, 65)
check("outside pixel white", v31 > 250,
    string.format("x=31 gray=%d, expected >250", v31))

local v38 = gray(pixels, 38, 65)
check("inside pixel solid", v38 < 10,
    string.format("x=38 gray=%d, expected <10", v38))

intermediates = findIntermediates(slice)
check("has AA fringe on left edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 3: Triangle — left diagonal edge
-- Triangle: (150,20), (120,70), (180,70).
-- Left edge from (150,20) to (120,70): at y=45 (midpoint), x = 135.
------------------------------------------------------------
print("\nTest 3: Triangle — left diagonal edge at y=45")
slice = hSlice(pixels, 45, 131, 139)
print("  H-section at y=45: " .. fmtSlice(slice))

intermediates = findIntermediates(slice)
check("has AA fringe on triangle edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 4: Triangle — right diagonal edge
-- Right edge from (150,20) to (180,70): at y=45, x = 165.
------------------------------------------------------------
print("\nTest 4: Triangle — right diagonal edge at y=45")
slice = hSlice(pixels, 45, 161, 169)
print("  H-section at y=45: " .. fmtSlice(slice))

intermediates = findIntermediates(slice)
check("has AA fringe on triangle right edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 5: Ellipse — right edge
-- Ellipse center (50,140), rx=35, ry=20. Right edge at x=85.
-- Sample at y=140 (center row) where the edge is exactly at x=85.
-- At y=145 (5 above bottom), the x edge is at:
--   x = 50 + 35*sqrt(1 - (5/20)^2) = 50 + 35*sqrt(0.9375) ≈ 83.88
------------------------------------------------------------
print("\nTest 5: Ellipse — right edge at y=145")
slice = hSlice(pixels, 145, 80, 88)
print("  H-section at y=145: " .. fmtSlice(slice))

local v80 = gray(pixels, 80, 145)
check("inside pixel solid", v80 < 10,
    string.format("x=80 gray=%d, expected <10", v80))

intermediates = findIntermediates(slice)
check("has AA fringe on ellipse edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 6: Ellipse — upper-right diagonal edge
-- At y=125 (15 above center), edge at x = 50 + 35*sqrt(1-(15/20)^2) ≈ 73.15
-- This tests the ellipse edge at a steep angle where X-direction scanline AA
-- produces fringe pixels. (Near-horizontal edges like the very top are a
-- known limitation of scanline AA — Y-direction coverage isn't computed.)
------------------------------------------------------------
print("\nTest 6: Ellipse — upper-right diagonal edge at y=125")
slice = hSlice(pixels, 125, 69, 77)
print("  H-section at y=125: " .. fmtSlice(slice))

intermediates = findIntermediates(slice)
check("has AA fringe on ellipse diagonal edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Summary
------------------------------------------------------------
T.summary()
