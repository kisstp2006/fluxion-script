var total = 0;
for (0..10) |i| {
    if (i % 2 == 0) continue;
    if (i > 7) break;
    total += i;
}
print(total);
// out: 16
var n = 0;
while (n < 100) : (n += 7) {}
print(n);
// out: 105
outer: for (0..3) |i| {
    for (0..3) |j| {
        if (j == 2) continue :outer;
        if (i == 2) break :outer;
        print(i, j);
    }
}
// out: 0 0
// out: 0 1
// out: 1 0
// out: 1 1
for ([10, 20, 30]) |x, i| print(i, x);
// out: 0 10
// out: 1 20
// out: 2 30
for ({"a": 1, "b": 2}) |k, v| print(k, v);
// out: a 1
// out: b 2
for ("hé!") |ch| print(ch);
// out: h
// out: é
// out: !
for (1..=3) |i| print(i);
// out: 1
// out: 2
// out: 3
const grade = 85;
const letter = switch (grade) {
    90...100 => "A",
    80...89 => "B",
    else => "C",
};
print(letter);
// out: B
const x = if (grade > 50) "pass" else "fail";
print(x);
// out: pass
switch (grade) {
    1, 2, 3 => print("small"),
    else => print("big"),
}
// out: big
var k = 0;
while (true) {
    k += 1;
    if (k == 3) break;
}
print(k);
// out: 3
const flag = k > 2;
print(switch (flag) { true => "yes", false => "no" });
// out: yes
