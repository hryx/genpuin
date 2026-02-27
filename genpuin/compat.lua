-- Portable bitwise operations for Lua 5.1 / 5.2 / 5.3+ / LuaJIT
--
-- Exports: band, bxor, rshift, lshift
-- All operate on 32-bit unsigned integers represented as Lua numbers.

local M = {}

-- Try to detect the runtime and pick the best available bit library.
if jit then
    -- LuaJIT: use the built-in bit library
    local bit = require("bit")
    M.band   = function(a, b) return bit.band(a, b) % 0x100000000 end
    M.bxor   = function(a, b) return bit.bxor(a, b) % 0x100000000 end
    M.rshift = function(a, n) return bit.rshift(a, n) % 0x100000000 end
    M.lshift = function(a, n) return bit.lshift(a, n) % 0x100000000 end

elseif _VERSION >= "Lua 5.3" then
    -- Lua 5.3+: compile native operators from strings at runtime,
    -- so this file's syntax stays valid on older Lua.
    local load = load or loadstring
    M.band   = load("return function(a, b) return (a & b) % 0x100000000 end")()
    M.bxor   = load("return function(a, b) return (a ~ b) % 0x100000000 end")()
    M.rshift = load("return function(a, n) return (a >> n) % 0x100000000 end")()
    M.lshift = load("return function(a, n) return (a << n) % 0x100000000 end")()

elseif _VERSION == "Lua 5.2" then
    -- Lua 5.2: use the standard bit32 library
    local bit32 = require("bit32")
    M.band   = bit32.band
    M.bxor   = bit32.bxor
    M.rshift = bit32.rshift
    M.lshift = bit32.lshift

else
    -- Lua 5.1 fallback: try LuaBitOp, then pure-math implementations
    local ok, bit = pcall(require, "bit")
    if ok then
        M.band   = function(a, b) return bit.band(a, b) % 0x100000000 end
        M.bxor   = function(a, b) return bit.bxor(a, b) % 0x100000000 end
        M.rshift = function(a, n) return bit.rshift(a, n) % 0x100000000 end
        M.lshift = function(a, n) return bit.lshift(a, n) % 0x100000000 end
    else
        -- Pure-math fallbacks (correct for 32-bit unsigned values)
        local floor = math.floor
        local MOD = 0x100000000  -- 2^32

        M.rshift = function(a, n)
            return floor(a / (2 ^ n)) % MOD
        end

        M.lshift = function(a, n)
            return (a * (2 ^ n)) % MOD
        end

        M.band = function(a, b)
            local result = 0
            local bit = 1
            for _ = 1, 32 do
                if a % 2 >= 1 and b % 2 >= 1 then
                    result = result + bit
                end
                a = floor(a / 2)
                b = floor(b / 2)
                bit = bit * 2
            end
            return result
        end

        M.bxor = function(a, b)
            local result = 0
            local bit = 1
            for _ = 1, 32 do
                local ab = a % 2 >= 1
                local bb = b % 2 >= 1
                if ab ~= bb then
                    result = result + bit
                end
                a = floor(a / 2)
                b = floor(b / 2)
                bit = bit * 2
            end
            return result
        end
    end
end

return M
