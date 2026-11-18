-- test-width.lua: a width option sets the output width in pixels, the
-- height following the canvas aspect rounded to the nearest pixel.

local T = require("test.testkit")

local check = T.check

local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function ppmSize(path)
    local w, h = (read(path) or ""):match("^P6%s+(%d+)%s+(%d+)")
    return tonumber(w), tonumber(h)
end

local function canvasScript(name, w, h)
    local path = "out/test/width-" .. name .. ".lua"
    write(path, string.format([[
gen.canvas(%d, %d)
gen.background({0.2, 0.3, 0.4})
gen.draw(gen.circle({%d / 2, %d / 2}, %d / 3), {fill = {1, 0.8, 0.1}})
gen.draw(gen.line({0, 0}, {%d, %d}), {stroke = {0, 0, 0}, strokeWidth = 2})
]], w, h, w, h, math.min(w, h), w, h))
    return path
end

local function renderError(script, out, opts)
    local ok, err = pcall(testing.render, script, out, opts)
    if ok then return nil end
    return err
end

print("Exact output sizes")

local cases = {
    {name = "square", w = 40, h = 40, sizes = {{40, 40}, {1, 1}, {100, 100}, {333, 333}}},
    {name = "three-two", w = 60, h = 40, sizes = {{60, 40}, {3, 2}, {90, 60}, {100, 67}, {7, 5}, {1, 1}}},
    {name = "odd", w = 801, h = 533, sizes = {{801, 533}, {1600, 1065}, {400, 266}, {1000, 665}, {123, 82}}},
}
for _, c in ipairs(cases) do
    local script = canvasScript(c.name, c.w, c.h)
    for _, size in ipairs(c.sizes) do
        local out = string.format("out/test/width-%s-%d.ppm", c.name, size[1])
        local err = renderError(script, out, {width = size[1]})
        local w, h = ppmSize(out)
        check(string.format("%dx%d canvas at width %d is %dx%d", c.w, c.h, size[1], size[1], size[2]),
            err == nil and w == size[1] and h == size[2], err or string.format("got %sx%s", w, h))
    end
end

local odd = canvasScript("odd", 801, 533)
check("supersampling keeps the size",
    renderError(odd, "out/test/width-odd-ss.ppm", {width = 160, ss = 4}) == nil
    and select(2, ppmSize("out/test/width-odd-ss.ppm")) == 106)

print("\nThe canvas width is the default")

local square = canvasScript("square", 40, 40)
renderError(square, "out/test/width-plain.ppm")
renderError(square, "out/test/width-same.ppm", {width = 40})
check("width equal to the canvas is byte for byte the default",
    read("out/test/width-plain.ppm") == read("out/test/width-same.ppm"))
renderError(square, "out/test/width-plain.png")
renderError(square, "out/test/width-same.png", {width = 40})
check("the same holds for PNG", read("out/test/width-plain.png") == read("out/test/width-same.png"))

print("\nAn SVG keeps its viewBox and takes the width as its display size")

local plain = (renderError(odd, "out/test/width-plain.svg") == nil) and read("out/test/width-plain.svg") or ""
local wide = (renderError(odd, "out/test/width-wide.svg", {width = 1600}) == nil) and read("out/test/width-wide.svg") or ""
check("without width the SVG is the canvas size",
    plain:find('width="801" height="533" viewBox="0 0 801 533"', 1, true) ~= nil, plain:sub(1, 200))
check("with width the SVG displays at the raster size",
    wide:find('width="1600" height="1065" viewBox="0 0 801 533"', 1, true) ~= nil, wide:sub(1, 200))
check("only the svg element changes",
    plain:gsub("^[^\n]*\n", "") == wide:gsub("^[^\n]*\n", ""))

print("\nBad widths")

local function widthError(name, width, message)
    local err = renderError(square, "out/test/width-bad.ppm", {width = width})
    check(name, err and err:find(message, 1, true), err)
end
local bad = "option 'width' must be a whole number of pixels from 1 to 32768"
widthError("zero", 0, bad)
widthError("a fraction", 12.5, bad)
widthError("a string", "abc", bad)
widthError("over the limit", 40000, bad)

write("out/test/width-tall.lua", "gen.canvas(10, 40)\n")
local err = renderError("out/test/width-tall.lua", "out/test/width-tall.ppm", {width = 10000})
check("a height over the limit names the size",
    err and err:find("width 10000 on a 10x40 canvas makes a 10000x40000 image, over the 32768 px limit on a side", 1, true), err)
err = renderError("out/test/width-tall.lua", "out/test/width-tall.ppm", {scale = 2})
check("testing.render has no scale", err and err:find("testing.render: unknown option 'scale'", 1, true), err)

print("\nIn-script exports")

gen.canvas(60, 40)
gen.background({1, 1, 1})
gen.draw(gen.circle({30, 20}, 10), {fill = {0, 0, 0}})

local ok
ok, err = pcall(gen.exportPpm, "out/test/width-export.ppm", {width = 90})
local w, h = ppmSize("out/test/width-export.ppm")
check("exportPpm takes a width", ok and w == 90 and h == 60, err or string.format("got %sx%s", w, h))
ok, err = pcall(gen.exportPpm, "out/test/width-export-plain.ppm")
w, h = ppmSize("out/test/width-export-plain.ppm")
check("exportPpm defaults to the canvas size", ok and w == 60 and h == 40, err)
ok, err = pcall(gen.exportPng, "out/test/width-export.png", {width = 30, ss = 2})
check("exportPng takes a width", ok, err)
local png = read("out/test/width-export.png") or ""
local function be32(s, i) local a, b, c, d = s:byte(i, i + 3) return ((a * 256 + b) * 256 + c) * 256 + d end
check("the PNG header says 30x20", #png > 24 and be32(png, 17) == 30 and be32(png, 21) == 20)
ok, err = pcall(gen.exportSvg, "out/test/width-export.svg", {width = 120})
check("exportSvg takes a width", ok and (read("out/test/width-export.svg") or ""):find('width="120" height="80" viewBox="0 0 60 40"', 1, true), err)

ok, err = pcall(gen.exportPng, "out/test/never.png", {scale = 2})
check("exportPng has no scale", not ok and err:find("gen.exportPng: unknown option 'scale'", 1, true), err)
ok, err = pcall(gen.exportPpm, "out/test/never.ppm", 2)
check("exportPpm takes a table, not a scale",
    not ok and err:find("gen.exportPpm: options must be a table such as {width = 1600}", 1, true), err)
ok, err = pcall(gen.exportPpm, "out/test/never.ppm", {widht = 2})
check("a misspelled option suggests the right one",
    not ok and err:find("gen.exportPpm: unknown option 'widht' (did you mean 'width'?)", 1, true), err)
ok, err = pcall(gen.exportSvg, "out/test/never.svg", {width = 0})
check("exportSvg checks the width", not ok and err:find(bad, 1, true), err)

print("\nSupersampling counts toward the limits")

ok, err = pcall(gen.exportPng, "out/test/never.png", {width = 32768, ss = 16})
check("a side over the limit names the output, ss and working size",
    not ok and err:find("width 32768 on a 60x40 canvas makes a 32768x21845 image, rendered at ss 16 as 524288x349520, "
        .. "over the 32768 px limit on a side. Use a smaller width or ss", 1, true), err)
ok, err = pcall(gen.exportPng, "out/test/never.png", {width = 16384, ss = 2})
check("a working raster over the pixel limit is refused",
    not ok and err:find("width 16384 on a 60x40 canvas makes a 16384x10923 image, rendered at ss 2 as 32768x21846, "
        .. "over the limit of 268435456 pixels in all (16384x16384). Use a smaller width or ss", 1, true), err)
ok, err = pcall(gen.exportPpm, "out/test/never.ppm", {width = 32768})
check("an output over the pixel limit is refused without ss",
    not ok and err:find("width 32768 on a 60x40 canvas makes a 32768x21845 image, "
        .. "over the limit of 268435456 pixels in all (16384x16384). Use a smaller width", 1, true)
    and not err:find("ss", 1, true), err)
err = renderError("out/test/width-tall.lua", "out/test/width-tall.ppm", {width = 1000, ss = 16})
check("testing.render gives the same message",
    err and err:find("width 1000 on a 10x40 canvas makes a 1000x4000 image, rendered at ss 16 as 16000x64000, "
        .. "over the 32768 px limit on a side. Use a smaller width or ss", 1, true), err)

local badSs = "option 'ss' must be a whole number from 1 to 16"
for _, ss in ipairs({0, 17, 2.5, -1, math.huge, "4"}) do
    ok, err = pcall(gen.exportPng, "out/test/never.png", {ss = ss})
    check("ss " .. tostring(ss) .. " is refused", not ok and err:find(badSs, 1, true), err)
end

T.summary()
