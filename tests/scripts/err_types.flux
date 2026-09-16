var seen: [string: int] = [:];
// error: `[:]` is not a map
fn mark() { seen["a"] = 1; }
struct Label {
    var text: string = 5;
    // error: field `text` must be string, not int
    var owner: Label = null;
    // error: field `owner` is Label, which cannot be null
}
var ghost: ?Phantom = null;
// error: `Phantom` is not a type
struct Player {
    var health: int = 100;
    var target: ?Player = null;
}

fn heal(p: Player, amount: int) {
    p.health += amount;
}

const p = Player{};
var count: int = "three";
// error: the variable must be int, not string
p.helth = 5;
// error: `Player` has no field or method `helth`
heal(p);
// error: `heal` takes 2 arguments, and is given 1
heal(p, 2.5);
// error: the argument must be an int, not a float
const hp: int = p.target.health;
// error: cannot read `health` of a value that may be null
var name = "x";
name = 5;
// error: the variable must be string, not int
const s = "a" + 1;
// error: cannot use `+` on string and int
if (p.health) {}
// error: a condition is a bool, and this is int
const q = undefined_name + 1;
// error: `undefined_name` is not declared
fn coro() int { await wait(1.0); return 1; }
var f: fn() int = coro;
// error: the variable must be fn() int, not fn() int (awaits)
var g: fn() int = || "text";
// error: the return value must be int, not string
fn read(x: any) int {
    return int(x);
}
// error: the return value must be int, but this may be an error
fn half(x: int) int {
    if (x > 0) return x / 2;
}
// error: `half` must return int, but can reach its end without returning
fn pick() int {
    var n = range(0, 100);
    return n;
    // error: the return value must be int, not [int]
}
