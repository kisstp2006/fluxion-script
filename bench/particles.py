class P:
    __slots__ = ('px','py','vx','vy')
    def __init__(s, px, py, vx, vy): s.px, s.py, s.vx, s.vy = px, py, vx, vy
ps = [P(float(i) % 640.0, float(i) % 480.0, float(i) % 7.0 - 3.0, float(i) % 5.0 - 2.0) for i in range(10000)]
dt = 1.0 / 60.0
for _ in range(600):
    for p in ps:
        p.px += p.vx * dt; p.py += p.vy * dt
        if p.px < 0 or p.px > 640: p.vx = -p.vx
        if p.py < 0 or p.py > 480: p.vy = -p.vy
print(sum(p.px for p in ps), sum(p.py for p in ps))
