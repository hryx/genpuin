-- testkit.lua — Minimal test framework and PPM helpers

local M = {}

-- ============================================================
-- Test runner state
-- ============================================================

local passed = 0
local failed = 0
local total = 0

-- Assert a condition. Prints PASS or FAIL with optional detail.
function M.check(name, ok, detail)
    total = total + 1
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. " — " .. (detail or ""))
    end
end

-- Print summary and exit with code 1 if any failures.
function M.summary()
    print(string.format("\n=== %d/%d passed, %d failed ===", passed, total, failed))
    if failed > 0 then os.exit(1) end
end

-- ============================================================
-- PPM reader
-- ============================================================

-- Read a P6 binary PPM file. Returns a 2D pixel table (0-indexed),
-- width, and height. Each pixel is {r, g, b} with values 0-255.
function M.readPpm(path)
    local f = io.open(path, "rb")
    if not f then error("cannot open " .. path) end
    local magic = f:read("*l")
    if magic ~= "P6" then error("expected P6, got " .. magic) end
    local line = f:read("*l")
    while line:sub(1, 1) == "#" do line = f:read("*l") end
    local w, h = line:match("(%d+)%s+(%d+)")
    w, h = tonumber(w), tonumber(h)
    local maxval = tonumber(f:read("*l"))
    if maxval ~= 255 then error("expected maxval 255, got " .. maxval) end
    local pixels = {}
    for y = 0, h - 1 do
        pixels[y] = {}
        for x = 0, w - 1 do
            local rgb = f:read(3)
            if not rgb or #rgb < 3 then error("truncated pixel data at " .. x .. "," .. y) end
            pixels[y][x] = {rgb:byte(1), rgb:byte(2), rgb:byte(3)}
        end
    end
    f:close()
    return pixels, w, h
end

-- ============================================================
-- Pixel helpers
-- ============================================================

-- Grayscale value at (x, y). Returns -1 if out of bounds.
function M.gray(pixels, x, y)
    local p = pixels[y] and pixels[y][x]
    if not p then return -1 end
    return p[1]
end

-- Vertical cross-section: list of {y=, v=} from y0 to y1 at column x.
function M.vSlice(pixels, x, y0, y1)
    local vals = {}
    for y = y0, y1 do
        vals[#vals + 1] = {y = y, v = M.gray(pixels, x, y)}
    end
    return vals
end

-- Horizontal cross-section: list of {y=x, v=} from x0 to x1 at row y.
function M.hSlice(pixels, y, x0, x1)
    local vals = {}
    for x = x0, x1 do
        vals[#vals + 1] = {y = x, v = M.gray(pixels, x, y)}
    end
    return vals
end

-- True if value is intermediate (not near-black or near-white).
function M.isIntermediate(v)
    return v > 5 and v < 250
end

-- Count pixels with value below threshold in a slice.
function M.countAffected(slice, threshold)
    threshold = threshold or 250
    local n = 0
    for _, s in ipairs(slice) do
        if s.v < threshold then n = n + 1 end
    end
    return n
end

-- Return sub-list of intermediate pixels from a slice.
function M.findIntermediates(slice)
    local result = {}
    for _, s in ipairs(slice) do
        if M.isIntermediate(s.v) then
            result[#result + 1] = s
        end
    end
    return result
end

-- Format a slice as "y17=255 y18=200 ..." for debug output.
function M.fmtSlice(slice)
    local parts = {}
    for _, s in ipairs(slice) do
        parts[#parts + 1] = string.format("y%d=%d", s.y, s.v)
    end
    return table.concat(parts, " ")
end

-- Render an example to PPM via bin/genpuin. Aborts on failure.
function M.render(example, output)
    local cmd = string.format('lua bin/genpuin %s -o %s', example, output)
    local ok = os.execute(cmd)
    if not ok then
        print("ABORT: render failed: " .. cmd)
        os.exit(1)
    end
end

return M
