// Numbers, strings and the operators between them.
print(1 + 2 * 3, (1 + 2) * 3, 7 / 2, 7 % 3, -7 / 2, -7 % 3);
// out: 7 9 3 1 -3 -1
print(7.0 / 2, 1.5 * 2, 0.1 + 0.2 == 0.3, 3 == 3.0);
// out: 3.5 3.0 false true
print(1 << 4, 255 & 15, 5 | 2, 5 ^ 1, ~0);
// out: 16 15 7 4 -1
print(9223372036854775807 +% 1);
// out: -9223372036854775808
const name = "Flux";
var count = 3;
count += 2;
print(f"{name} has {count} letters? {name.len == count}");
// out: Flux has 5 letters? false
print(f"pi is about {3.14159:.2} and {42:>6}|{7:<4}|{255:x}|{5:03}");
// out: pi is about 3.14 and     42|7   |ff|005
print("a" + "b" * 3, "héllo".len, "abc"[1], "hello"[1..3]);
// out: abbb 5 b el
print(true and false, true or false, !true, 1 < 2 and 2 < 3);
// out: false true false true
var s = "";
for (0..5) |i| s = s + str(i);
print(s);
// out: 01234
print(int("42") catch 0, int("x") catch -1, float("2.5") catch 0.0, int(3.9), str(1.0));
// out: 42 -1 2.5 3 1.0
const multi =
    \\first
    \\second
;
print(multi);
// out: first
// out: second
print(typeof(1), typeof(1.0), typeof("s"), typeof(null), typeof([1]), typeof({"a": 1}));
// out: int float string null list map
