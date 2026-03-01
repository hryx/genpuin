local rand = require("genpuin.rand")

local M = {}

-- Rewrite axiom string using production rules for n iterations.
-- rules: {char = "replacement"} for deterministic
--        {char = {{"replacement1", weight}, {"replacement2", weight}, ...}} for stochastic
-- Characters without rules are preserved unchanged.
function M.rewrite(axiom, rules, n)
    local str = axiom
    for _ = 1, n do
        local buf = {}
        for i = 1, #str do
            local ch = str:sub(i, i)
            local rule = rules[ch]
            if rule == nil then
                buf[#buf + 1] = ch
            elseif type(rule) == "string" then
                buf[#buf + 1] = rule
            else
                -- Stochastic: rule is {{replacement, weight}, ...}
                local total = 0
                for j = 1, #rule do total = total + rule[j][2] end
                local r = rand.rand() * total
                local acc = 0
                for j = 1, #rule do
                    acc = acc + rule[j][2]
                    if r < acc then
                        buf[#buf + 1] = rule[j][1]
                        break
                    end
                end
                -- Fallback (rounding edge case)
                if #buf < i then buf[#buf + 1] = rule[#rule][1] end
            end
        end
        str = table.concat(buf)
    end
    return str
end

return M
