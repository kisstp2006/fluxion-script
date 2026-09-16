local words = {"alpha","beta","gamma","delta","epsilon","zeta","eta","theta"}
local counts = {}
local parts = {}
local n = 0
for i = 0, 400000 - 1 do
  local w = words[i % 8 + 1]
  local key = w .. (i % 100)
  if counts[key] == nil then n = n + 1 end
  counts[key] = (counts[key] or 0) + 1
  if i % 1000 == 0 then parts[#parts+1] = string.upper(key) end
end
local total = 0
for _, v in pairs(counts) do total = total + v end
print(n, total, #table.concat(parts, ","))
