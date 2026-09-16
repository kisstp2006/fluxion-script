struct Particle {
    var pos: vec2 = vec2(0, 0);
    var vel: vec2 = vec2(0, 0);
}
var ps: [Particle] = [];
for (0..10000) |i| {
    const f = float(i);
    ps.push(Particle{ .pos = vec2(f % 640.0, f % 480.0), .vel = vec2(f % 7.0 - 3.0, f % 5.0 - 2.0) });
}
const dt = 1.0 / 60.0;
for (0..600) |_| {
    for (ps) |p| {
        p.pos += p.vel * dt;
        if (p.pos.x < 0 or p.pos.x > 640) p.vel.x = -p.vel.x;
        if (p.pos.y < 0 or p.pos.y > 480) p.vel.y = -p.vel.y;
    }
}
var sum = vec2(0, 0);
for (ps) |p| sum += p.pos;
print(sum);
