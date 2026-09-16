struct Vec {
    var x: float = 0;
    var y: float = 0;
    const ZERO = 0;

    fn init(x: float, y: float) Vec {
        return Vec{ .x = x, .y = y };
    }

    fn length(self) float {
        return (self.x * self.x + self.y * self.y);
    }

    fn scale(self, k: float) {
        self.x *= k;
        self.y *= k;
    }
}
var v = Vec.init(3, 4);
print(v.length(), v.x, Vec.ZERO);
// out: 25.0 3.0 0
v.scale(2);
print(v);
// out: Vec{ .x = 6.0, .y = 8.0 }

struct Actor {
    var name = "actor";
    var hp: int = 10;
    var tags: [string];

    fn describe(self) string {
        return f"{self.name} ({self.hp})";
    }

    fn damage(self, amount: int) {
        self.hp -= amount;
    }
}
struct Boss extends Actor {
    var phase = 1;

    fn damage(self, amount: int) {
        self.hp -= amount / 2;
        if (self.hp < 5) self.phase = 2;
    }
}
const a = Actor{ .name = "goblin" };
const b = Boss{ .name = "dragon", .hp = 20 };
a.damage(3);
b.damage(30);
print(a.describe(), b.describe(), b.phase);
// out: goblin (7) dragon (5) 1
b.tags.push("fire");
print(a.tags.len, b.tags);
// out: 0 ["fire"]
const actors: [Actor] = [a, b];
for (actors) |x| print(x.name);
// out: goblin
// out: dragon
print(b is Actor, a is Boss);
// out: true false

// A whole number written as a float field's default is a float.
struct Body {
    const G: float = 10;
    var mass: float = 2;
    var drag: ?float = 1;
}
const body = Body{};
print(body.mass * Body.G + 0.5, body.drag);
// out: 20.5 1.0
