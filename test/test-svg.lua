-- test-svg.lua: SVG export writes what the PNG shows or refuses with a
-- message, and --vector-only leaves post passes out.

local T = require("test.testkit")

local check = T.check

local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

local function renderError(script, out, opts)
    os.remove(out)
    local ok, err = pcall(testing.render, script, out, opts)
    if ok then return nil end
    return err
end

print("A post pass is refused")

write("out/test/svg-pass.lua", [[
gen.canvas(40, 30)
gen.draw(gen.circle({10, 10}, 5), {fill = {1, 0, 0}})
gen.post.invert()
gen.draw(gen.rect(20, 5, 10, 10), {fill = {0, 0, 1}})
]])
local err = renderError("out/test/svg-pass.lua", "out/test/svg-pass.svg")
check("strict export fails", err ~= nil)
check("the error names the pass and its line",
    err and err:find("svg-pass.lua:3: gen.post.invert needs pixels and has no vector form", 1, true), err)
check("no file is written", read("out/test/svg-pass.svg") == nil)

print("\n--vector-only leaves the pass out")

err = renderError("out/test/svg-pass.lua", "out/test/svg-pass.svg", {vectorOnly = true})
check("vector-only export succeeds", err == nil, err)
local doc = read("out/test/svg-pass.svg") or ""
check("the draw before the pass is kept", doc:find('fill="rgb(255,0,0)"', 1, true) ~= nil)
check("the draw after the pass is kept", doc:find('fill="rgb(0,0,255)"', 1, true) ~= nil)
check("nothing inverted the colors", doc:find("filter", 1, true) == nil)

print("\nDraws SVG cannot show are refused")

write("out/test/svg-add.lua", [[
gen.canvas(20, 20)
gen.draw(gen.rect(0, 0, 5, 5), {fill = {1, 0, 0}})
gen.draw(gen.circle({10, 10}, 5), {fill = {1, 0, 0}, blendMode = "add"})
]])
err = renderError("out/test/svg-add.lua", "out/test/svg-add.svg", {vectorOnly = true})
check("blend add fails even with vector-only",
    err and err:find("draw 2 (circle): blendMode 'add' has no SVG form", 1, true), err)
check("the add canvas still renders to PNG", renderError("out/test/svg-add.lua", "out/test/svg-add.png") == nil)

write("out/test/svg-blob.lua", [[
gen.canvas(20, 20)
gen.draw({type = "blob"}, {fill = {1, 1, 1}})
]])
for _, vectorOnly in ipairs({false, true}) do
    err = renderError("out/test/svg-blob.lua", "out/test/svg-blob.svg", {vectorOnly = vectorOnly})
    check("an unknown shape fails SVG export, vectorOnly " .. tostring(vectorOnly),
        err and err:find("unknown shape type 'blob'", 1, true), err)
end

print("\nThe SVG follows the rasterizer")

write("out/test/svg-follow.lua", [[
gen.canvas(40, 40)
gen.draw(gen.rect(0, 0, 10, 10), {fill = {1, 0, 0}})
gen.layer("top")
gen.draw(gen.polyline({{0, 0}, {20, 0}, {20, 20}}), {fill = {0, 1, 0}, stroke = {0, 0, 1, 0.5}, strokeWidth = 4})
gen.draw(gen.circle({20, 20}, 5), {fill = "red"})
]])
err = renderError("out/test/svg-follow.lua", "out/test/svg-follow.svg")
check("the canvas exports", err == nil, err)
doc = read("out/test/svg-follow.svg") or ""
check("the default black background is written", doc:find('fill="rgb(0,0,0)"', 1, true) ~= nil)
check("a draw before the first layer is kept", doc:find('fill="rgb(255,0,0)"', 1, true) ~= nil)
check("the layer is a group", doc:find('<g id="top">', 1, true) ~= nil)
check("an open shape has no fill", doc:find("rgb(0,255,0)", 1, true) == nil)
check("color alpha becomes stroke-opacity", doc:find('stroke-opacity="0.5"', 1, true) ~= nil)
check("joins are round", doc:find('stroke-linejoin="round"', 1, true) ~= nil)
check("a string fill paints nothing, as in the PNG", doc:find("red", 1, true) == nil)

print("\ngen.exportSvg")

gen.canvas(20, 20)
gen.draw(gen.circle({10, 10}, 5), {fill = {1, 1, 1}})
gen.post.invert()
local ok
ok, err = pcall(gen.exportSvg, "out/test/svg-export.svg")
check("exportSvg refuses a pass", not ok)
check("the error names the pass's line",
    err and err:find("test%-svg%.lua:98: gen%.post%.invert needs pixels and has no vector form"), err)
check("the error offers both ways out",
    err and err:find("(use gen.exportPng, or gen.exportSvg(filename, {vectorOnly = true}) to export just the shapes)", 1, true), err)
local left
ok, left = pcall(gen.exportSvg, "out/test/svg-export.svg", {vectorOnly = true})
check("exportSvg with vectorOnly writes", ok, left)
check("exportSvg returns how many passes it left out", left == 1, tostring(left))
ok, err = pcall(gen.exportSvg, "out/test/svg-export.svg", {vectoronly = true})
check("an unknown option fails", not ok and err:find("unknown option 'vectoronly'", 1, true), err)

T.summary()
