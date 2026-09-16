local function make(d) if d == 0 then return {} end return {make(d-1), make(d-1)} end
local function check(t) if t[1] then return 1 + check(t[1]) + check(t[2]) end return 1 end
local maxd = 16
local long = make(maxd)
for d = 4, maxd, 2 do
  local it = 1 << (maxd - d + 4)
  local total = 0
  for i = 1, it do total = total + check(make(d)) end
  print(string.format("%d trees of depth %d check %d", it, d, total))
end
print(string.format("long lived tree check %d", check(long)))
