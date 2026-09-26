fn add(a: int, b: int) int {
    return a + b;
}
fn greet(name, greeting = "hello") string {
    return f"{greeting}, {name}!";
}
fn fib(n: int) int {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}
print(add(2, 3), greet("Ada"), greet("Bob", "hi"), fib(20));
// out: 5 hello, Ada! hi, Bob! 6765
fn counter() fn() int {
    var count = 0;
    return fn () int {
        count += 1;
        return count;
    };
}
const next = counter();
next();
next();
print(next());
// out: 3
const double = |x: int| x * 2;
print(double(21));
// out: 42
fn apply(f: fn(int) int, x: int) int {
    return f(x);
}
print(apply(|v| v + 1, 9));
// out: 10
var fns: [fn() int] = [];
for (0..3) |i| fns.push(fn () int { return i * 10; });
for (fns) |f| print(f());
// out: 0
// out: 10
// out: 20
fn outer() int {
    const a = 5;
    fn inner(b: int) int {
        return a + b;
    }
    return inner(10);
}
print(outer());
// out: 15
// A value of any type in a local, given where a typed parameter is: checked
// where it goes, and the arguments after it still where they belong.
fn pair(a: int, b: int) int {
    return a * 10 + b;
}
fn given() int {
    const first: any = 4;
    return pair(first, 2);
}
print(given());
// out: 42
struct Spot {
    var x: int = 0;
    var y: int = 0;
    fn sum(self, a: int, b: int) int {
        return self.x + self.y + a * 10 + b;
    }
}
fn gathered() {
    const first: any = 4;
    const xs: [int] = [first, 2];
    const spot = Spot{ .x = first, .y = 2 };
    print(xs, spot.x, spot.y, spot.sum(first, 2));
}
gathered();
// out: [4, 2] 4 2 48
