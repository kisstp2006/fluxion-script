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
