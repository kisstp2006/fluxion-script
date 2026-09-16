struct Node {
    var left: ?Node = null;
    var right: ?Node = null;
}
fn make(depth: int) Node {
    if (depth == 0) return Node{};
    return Node{ .left = make(depth - 1), .right = make(depth - 1) };
}
fn check(n: Node) int {
    if (n.left) |l| return 1 + check(l) + check(n.right.?);
    return 1;
}
const max_depth = 16;
const long_lived = make(max_depth);
var depth = 4;
while (depth <= max_depth) : (depth += 2) {
    const iterations = 1 << (max_depth - depth + 4);
    var total = 0;
    for (0..iterations) |_| total += check(make(depth));
    print(f"{iterations} trees of depth {depth} check {total}");
}
print(f"long lived tree check {check(long_lived)}");
