const math = @import("math");

// No turn, and a quarter turn about +y: -z goes to -x.
const none = quat();
print(none, none * vec3(1, 2, 3));
// out: quat(0.0, 0.0, 0.0, 1.0) (1.0, 2.0, 3.0)
const quarter = quat(vec3(0, 1, 0), math.pi / 2);
const turned = quarter * vec3(0, 0, -1);
print(math.approx_eq(turned.x, -1.0), math.approx_eq(turned.z, 0.0), turned == quarter.rotate(vec3(0, 0, -1)));
// out: true true true

// Two quarter turns are a half turn; the inverse undoes it.
const half = quarter * quarter;
print(math.approx_eq(half.angle(), math.pi), math.approx_eq((half * half.inverse()).w, 1.0));
// out: true true

// Euler angles go in and come back out.
const e = quat(vec3(0.3, -1.2, 0.5)).euler();
print(math.approx_eq(e.x, 0.3), math.approx_eq(e.y, -1.2), math.approx_eq(e.z, 0.5));
// out: true true true

// Halfway along the shortest arc, and a typed field.
const mid = none.slerp(quarter, 0.5);
print(math.approx_eq(mid.angle_to(none), math.pi / 4), mid.axis().y > 0.99);
// out: true true
struct Turret {
    var aim: quat = quat();
}
var t = Turret{};
t.aim = t.aim * quat(vec3(1, 0, 0), 0.25);
print(math.approx_eq(t.aim.angle(), 0.25), typeof(t.aim), t.aim.w < 1.0);
// out: true quat true
