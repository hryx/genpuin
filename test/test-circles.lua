-- test-circles.lua — Circle anti-aliasing verification
-- Renders examples/test-circles.lua to PPM and checks cross-sections at
-- circle edges for AA fringe pixels.

local T = require("test.testkit")

local check = T.check
local gray = T.gray
local vSlice = T.vSlice
local hSlice = T.hSlice
local countAffected = T.countAffected
local findIntermediates = T.findIntermediates
local fmtSlice = T.fmtSlice

------------------------------------------------------------
-- Render
------------------------------------------------------------
print("Rendering test-circles.ppm...")
T.render("examples/test-circles.lua", "out/test/test-circles.ppm")

local pixels, W, H = T.readPpm("out/test/test-circles.ppm")
print(string.format("Loaded %dx%d PPM\n", W, H))

------------------------------------------------------------
-- Test 1: Filled circle, r=30, center at (50,50)
-- Sample horizontal slice through center at y=50, crossing right edge at x=80
------------------------------------------------------------
print("Test 1: Filled circle r=30 — right edge")
local slice = hSlice(pixels, 50, 76, 84)
print("  H-section at y=50, x=76..84: " .. fmtSlice(slice))

-- Inside the circle (x=76,77,78) should be solid black
local v76 = gray(pixels, 76, 50)
check("inside pixel solid", v76 < 10,
    string.format("x=76 gray=%d, expected <10", v76))

-- Outside the circle (x=83,84) should be white
local v84 = gray(pixels, 84, 50)
check("outside pixel white", v84 > 250,
    string.format("x=84 gray=%d, expected >250", v84))

-- Edge should have AA fringe (intermediate values)
local intermediates = findIntermediates(slice)
check("has AA fringe at edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 2: Filled circle, r=30 — top edge at (50,20)
-- Sample vertical slice at x=50 crossing top edge at y=20
------------------------------------------------------------
print("\nTest 2: Filled circle r=30 — top edge")
slice = vSlice(pixels, 50, 16, 24)
print("  V-section at x=50, y=16..24: " .. fmtSlice(slice))

local v16 = gray(pixels, 50, 16)
check("outside pixel white", v16 > 250,
    string.format("y=16 gray=%d, expected >250", v16))

local v24 = gray(pixels, 50, 24)
check("inside pixel solid", v24 < 10,
    string.format("y=24 gray=%d, expected <10", v24))

intermediates = findIntermediates(slice)
check("has AA fringe at top edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 3: Filled circle, r=30 — diagonal edge (~45 degrees)
-- At 45 degrees from center (50,50), edge is at ~(71,29).
-- Sample a few pixels around that area.
------------------------------------------------------------
print("\nTest 3: Filled circle r=30 — diagonal edge")
-- At angle 45°, edge at (50+21.2, 50-21.2) ≈ (71, 29)
slice = vSlice(pixels, 71, 25, 33)
print("  V-section at x=71, y=25..33: " .. fmtSlice(slice))

intermediates = findIntermediates(slice)
check("has AA fringe at diagonal", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 4: Stroked circle, r=30, strokeWidth=1, center at (140,50)
-- At cardinal directions the edge hits integer distance (same as 1px
-- horizontal lines) so sample at y=40 where the edge is at a non-integer
-- x position: x = 140 + sqrt(30²-10²) ≈ 168.28
------------------------------------------------------------
print("\nTest 4: Stroked circle r=30, sw=1 — non-cardinal edge")
slice = hSlice(pixels, 40, 164, 172)
print("  H-section at y=40, x=164..172: " .. fmtSlice(slice))

-- Should have at least one dark pixel (the stroke)
local affected = countAffected(slice)
check("stroke pixels present", affected >= 1,
    string.format("affected=%d", affected))

-- Should have AA fringe
intermediates = findIntermediates(slice)
check("has AA fringe on stroke", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 5: Small filled circle, r=5, center at (50,140)
-- Right edge at x=55.
------------------------------------------------------------
print("\nTest 5: Small filled circle r=5 — right edge")
slice = hSlice(pixels, 140, 51, 59)
print("  H-section at y=140, x=51..59: " .. fmtSlice(slice))

local v51 = gray(pixels, 51, 140)
check("inside pixel solid", v51 < 10,
    string.format("x=51 gray=%d, expected <10", v51))

intermediates = findIntermediates(slice)
check("has AA fringe at edge", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Test 6: Small stroked circle, r=5, strokeWidth=0.5, center at (140,140)
-- At y=137 (3 above center), edge at x = 140 + sqrt(25-9) = 144.0.
-- At y=138 (2 above center), edge at x = 140 + sqrt(25-4) ≈ 144.58.
-- Sample at y=138 for non-integer alignment.
------------------------------------------------------------
print("\nTest 6: Small stroked circle r=5, sw=0.5 — non-cardinal edge")
slice = hSlice(pixels, 138, 141, 149)
print("  H-section at y=138, x=141..149: " .. fmtSlice(slice))

affected = countAffected(slice)
check("stroke pixels present", affected >= 1,
    string.format("affected=%d", affected))

intermediates = findIntermediates(slice)
check("has AA fringe on stroke", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

------------------------------------------------------------
-- Summary
------------------------------------------------------------
T.summary()
