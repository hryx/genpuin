-- run.lua — Run all test/test-*.lua files
-- Usage: lua test/run.lua

local function glob(pattern)
    local f = io.popen('ls ' .. pattern .. ' 2>/dev/null')
    local files = {}
    for line in f:lines() do
        files[#files + 1] = line
    end
    f:close()
    return files
end

local files = glob("test/test-*.lua")
if #files == 0 then
    print("No test files found.")
    os.exit(0)
end

local failures = {}

for _, file in ipairs(files) do
    print(string.format("\n──── %s ────", file))
    local ok = os.execute("lua " .. file)
    if not ok then
        failures[#failures + 1] = file
    end
end

print("\n══════════════════════════════")
if #failures == 0 then
    print(string.format("All %d test file(s) passed.", #files))
else
    print(string.format("%d/%d test file(s) failed:", #failures, #files))
    for _, f in ipairs(failures) do
        print("  " .. f)
    end
    os.exit(1)
end
