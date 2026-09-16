const math = @import("math");

var pos = vec2(1, 2);
const vel = vec2(3, 4);
pos += vel * 2.0;
print(pos, pos.x, pos.y, vel.length());
// out: (7.0, 10.0) 7.0 10.0 5.0
pos.x = 0;
pos.y += 1;
print(pos, vel.normalized(), vel.dot(vec2(1, 0)));
// out: (0.0, 11.0) (0.6, 0.8) 3.0
print(vec2(0, 0).distance_to(vec2(3, 4)), vec2(1, 1) == vec2(1, 1), -vel);
// out: 5.0 true (-3.0, -4.0)
const p = vec3(1, 2, 3);
print(p + vec3(1, 1, 1), p.cross(vec3(0, 0, 1)), p.z);
// out: (2.0, 3.0, 4.0) (2.0, -1.0, 0.0) 3.0
const r = vec2(1, 0).rotated(math.pi / 2);
print(math.approx_eq(r.x, 0.0), math.approx_eq(r.y, 1.0));
// out: true true
print(vec2(0, 0).move_toward(vec2(10, 0), 3), vec2(3, 4).limit_length(1).length());
// out: (3.0, 0.0) 1.0

struct Body {
    var position: vec2 = vec2(0, 0);
    var velocity = vec2(1, 1);
}
var b = Body{};
b.position.x = 5;
b.position += b.velocity;
print(b.position);
// out: (6.0, 1.0)
const c = color("#FF8000");
print(c.r, c.g > 0.5, c.b, c.a);
// out: 1.0 true 0.0 1.0
print(math.floor(2.7), math.sqrt(16.0), math.pow(2, 10), math.mod(-1, 5), math.lerp(0.0, 10.0, 0.25));
// out: 2 4.0 1024 4 2.5
