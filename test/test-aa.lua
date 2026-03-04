-- test-aa.lua — Anti-aliasing verification
-- Renders examples/test-aa.lua to PPM and checks cross-sections for correct
-- AA fringe pixels, line widths, and gap-free continuity.

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
print("Rendering test-aa.ppm...")
T.render("examples/test-aa.lua", "out/ppm/test-aa.ppm")

local pixels, W, H = T.readPpm("out/ppm/test-aa.ppm")
print(string.format("Loaded %dx%d PPM\n", W, H))

------------------------------------------------------------
-- Test 1: Horizontal line at y=20, strokeWidth=0.3
------------------------------------------------------------
print("Test 1: Horizontal 0.3px line at y=20")
local slice = vSlice(pixels, 100, 17, 23)
print("  Cross-section: " .. fmtSlice(slice))

local v20 = gray(pixels, 100, 20)
check("center pixel partially dark", v20 < 240 and v20 > 0,
    string.format("y=20 gray=%d, expected partial coverage (roughly 100-220)", v20))

local v19 = gray(pixels, 100, 19)
local v21 = gray(pixels, 100, 21)
check("neighbors mostly white", v19 > 200 and v21 > 200,
    string.format("y=19=%d y=21=%d, expected >200", v19, v21))

local intermediates = findIntermediates(slice)
check("has intermediate (AA) pixels", #intermediates >= 1,
    string.format("found %d intermediate pixels", #intermediates))

local noGaps = true
local gapDetail = ""
for x = 30, 170, 10 do
    local v = gray(pixels, x, 20)
    if v >= 250 then
        noGaps = false
        gapDetail = string.format("gap at x=%d (gray=%d)", x, v)
        break
    end
end
check("no gaps along line", noGaps, gapDetail)

------------------------------------------------------------
-- Test 2: Horizontal line at y=50, strokeWidth=1.0
------------------------------------------------------------
print("\nTest 2: Horizontal 1.0px line at y=50")
slice = vSlice(pixels, 100, 47, 53)
print("  Cross-section: " .. fmtSlice(slice))

local v50 = gray(pixels, 100, 50)
check("center pixel dark", v50 < 50,
    string.format("y=50 gray=%d, expected <50", v50))

-- A 1px line perfectly aligned to an integer pixel center correctly has no AA
-- fringe — the line covers exactly 1 pixel. AA is verified on diagonal lines
-- (Tests 4-6) where sub-pixel alignment naturally occurs.
local affected = countAffected(slice)
check("affected width is 1px", affected == 1,
    string.format("affected=%d pixels, expected exactly 1", affected))

------------------------------------------------------------
-- Test 3: Horizontal line at y=80, strokeWidth=2.5
------------------------------------------------------------
print("\nTest 3: Horizontal 2.5px line at y=80")
slice = vSlice(pixels, 100, 76, 84)
print("  Cross-section: " .. fmtSlice(slice))

local v79 = gray(pixels, 100, 79)
local v80 = gray(pixels, 100, 80)
local v81 = gray(pixels, 100, 81)
check("center solid", v80 < 10,
    string.format("y=80 gray=%d, expected <10", v80))
-- y=79 and y=81 are at distance 1.0 from center with halfW=1.25,
-- placing them in the AA fringe (inner=0.75). Coverage = 0.75 → gray ~64.
check("near-center substantially dark", v79 < 100 and v81 < 100,
    string.format("y=79=%d y=81=%d, expected <100", v79, v81))

intermediates = findIntermediates(slice)
check("has AA fringe at edges", #intermediates >= 1,
    string.format("found %d intermediate pixels: %s", #intermediates, fmtSlice(intermediates)))

affected = countAffected(slice)
check("affected width matches strokeWidth", affected >= 2 and affected <= 5,
    string.format("affected=%d pixels, expected 2-5", affected))

local v76 = gray(pixels, 100, 76)
local v84 = gray(pixels, 100, 84)
check("far pixels white", v76 > 250 and v84 > 250,
    string.format("y=76=%d y=84=%d, expected >250", v76, v84))

------------------------------------------------------------
-- Test 4: 45-degree diagonal, strokeWidth=1.0
------------------------------------------------------------
print("\nTest 4: 45-degree 1.0px diagonal")
-- Line from (10,110) to (70,170). At x=40 the line is at y=140.
slice = vSlice(pixels, 40, 137, 143)
print("  Cross-section at x=40: " .. fmtSlice(slice))

affected = countAffected(slice)
check("pixels affected at midpoint", affected >= 1,
    string.format("affected=%d", affected))

intermediates = findIntermediates(slice)
check("has AA fringe", #intermediates >= 1,
    string.format("found %d intermediate pixels", #intermediates))

------------------------------------------------------------
-- Test 5: 45-degree diagonal, strokeWidth=2.5
------------------------------------------------------------
print("\nTest 5: 45-degree 2.5px diagonal")
-- Line from (10,155) to (55,200). Midpoint ~(32,177).
slice = vSlice(pixels, 32, 173, 181)
print("  Cross-section at x=32: " .. fmtSlice(slice))

affected = countAffected(slice)
check("pixels affected", affected >= 2,
    string.format("affected=%d, expected >=2", affected))

intermediates = findIntermediates(slice)
check("has AA fringe", #intermediates >= 1,
    string.format("found %d intermediate pixels", #intermediates))

------------------------------------------------------------
-- Test 6: Steep (~66 degree) line, strokeWidth=1.0
------------------------------------------------------------
print("\nTest 6: Steep ~66-degree 1.0px line")
-- Line from (150,110) to (170,190). Midpoint ~(160,150).
-- Nearly vertical, so horizontal cross-section is more revealing.
slice = hSlice(pixels, 150, 157, 163)
print("  H-section at y=150: " .. fmtSlice(slice))

affected = countAffected(slice)
check("pixels affected", affected >= 1,
    string.format("affected=%d", affected))

intermediates = findIntermediates(slice)
check("has AA fringe", #intermediates >= 1,
    string.format("found %d intermediate pixels", #intermediates))

------------------------------------------------------------
-- Summary
------------------------------------------------------------
T.summary()
