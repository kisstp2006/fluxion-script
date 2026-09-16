// What a built-in function gives is what its type says it gives: code
// typed from it reads the value as that type.
const math = @import("math");

print(min(3, 2.5, 7), max(2, 1.5), min([4, 2, 9]), max([1.5, 0.5]));
// out: 2.5 2.0 2 1.5

print(math.pow(2, 10), math.pow(-1, -3), math.pow(2.0, -1));
// out: 1024 -1 0.5

print(math.floor(2.7), math.round(-1.5), math.wrap(7, 0, 5), math.wrap(7.5, 0, 5));
// out: 2 -2 2 2.5

var empty: [float] = [];
print(empty.sum() + 0.5);
// out: 0.5

// From a value of any type, a conversion may meet text that is no number.
fn parse(x: any) int {
    return int(x) catch -1;
}
print(parse("42"), parse("forty"), parse(7.9));
// out: 42 -1 7

fn loose(x: any, y: any) any {
    return math.mod(x, y);
}
print(loose(7, 3), loose(7.5, 2));
// out: 1 1.5

print(math.floor(math.nan));
// panic: math.floor(nan) has no int value
