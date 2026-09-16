const math = @import("math");
struct Body {
    var x: float = 0;
    var y: float = 0;
    var z: float = 0;
    var vx: float = 0;
    var vy: float = 0;
    var vz: float = 0;
    var mass: float = 0;
}
fn advance(bodies: [Body], dt: float) {
    const n = bodies.len;
    for (0..n) |i| {
        const a = bodies[i];
        for (i + 1..n) |j| {
            const b = bodies[j];
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            const dz = a.z - b.z;
            const d2 = dx * dx + dy * dy + dz * dz;
            const mag = dt / (d2 * math.sqrt(d2));
            a.vx -= dx * b.mass * mag;
            a.vy -= dy * b.mass * mag;
            a.vz -= dz * b.mass * mag;
            b.vx += dx * a.mass * mag;
            b.vy += dy * a.mass * mag;
            b.vz += dz * a.mass * mag;
        }
    }
    for (bodies) |b| {
        b.x += dt * b.vx;
        b.y += dt * b.vy;
        b.z += dt * b.vz;
    }
}
fn energy(bodies: [Body]) float {
    var e = 0.0;
    const n = bodies.len;
    for (0..n) |i| {
        const a = bodies[i];
        e += 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz);
        for (i + 1..n) |j| {
            const b = bodies[j];
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            const dz = a.z - b.z;
            e -= a.mass * b.mass / math.sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}
const pi = 3.141592653589793;
const solar = 4.0 * pi * pi;
const days = 365.24;
var bodies: [Body] = [
    Body{ .mass = solar },
    Body{ .x = 4.84143144246472090e+00, .y = -1.16032004402742839e+00, .z = -1.03622044471123109e-01, .vx = 1.66007664274403694e-03 * days, .vy = 7.69901118419740425e-03 * days, .vz = -6.90460016972063023e-05 * days, .mass = 9.54791938424326609e-04 * solar },
    Body{ .x = 8.34336671824457987e+00, .y = 4.12479856412430479e+00, .z = -4.03523417114321381e-01, .vx = -2.76742510726862411e-03 * days, .vy = 4.99852801234917238e-03 * days, .vz = 2.30417297573763929e-05 * days, .mass = 2.85885980666130812e-04 * solar },
    Body{ .x = 1.28943695621391310e+01, .y = -1.51111514016986312e+01, .z = -2.23307578892655734e-01, .vx = 2.96460137564761618e-03 * days, .vy = 2.37847173959480950e-03 * days, .vz = -2.96589568540237556e-05 * days, .mass = 4.36624404335156298e-05 * solar },
    Body{ .x = 1.53796971148509165e+01, .y = -2.59193146099879641e+01, .z = 1.79258772950371181e-01, .vx = 2.68067772490389322e-03 * days, .vy = 1.62824170038242295e-03 * days, .vz = -9.51592254519715870e-05 * days, .mass = 5.15138902046611451e-05 * solar },
];
var px = 0.0;
var py = 0.0;
var pz = 0.0;
for (bodies) |b| {
    px += b.vx * b.mass;
    py += b.vy * b.mass;
    pz += b.vz * b.mass;
}
bodies[0].vx = -px / solar;
bodies[0].vy = -py / solar;
bodies[0].vz = -pz / solar;
print(f"{energy(bodies):.9f}");
for (0..500000) |_| advance(bodies, 0.01);
print(f"{energy(bodies):.9f}");
