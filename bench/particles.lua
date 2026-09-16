local ps = {}
for i = 0, 10000 - 1 do
  local f = i + 0.0
  ps[#ps+1] = {px = f % 640.0, py = f % 480.0, vx = f % 7.0 - 3.0, vy = f % 5.0 - 2.0}
end
local dt = 1.0 / 60.0
for _ = 1, 600 do
  for i = 1, #ps do
    local p = ps[i]
    p.px = p.px + p.vx * dt; p.py = p.py + p.vy * dt
    if p.px < 0 or p.px > 640 then p.vx = -p.vx end
    if p.py < 0 or p.py > 480 then p.vy = -p.vy end
  end
end
local sx, sy = 0, 0
for i = 1, #ps do sx = sx + ps[i].px; sy = sy + ps[i].py end
print(sx, sy)
