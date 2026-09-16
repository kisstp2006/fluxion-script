struct Enemy {
    var name: string = "enemy";
    var target: ?Enemy = null;
}

fn find(items: [string], wanted: string) ?int {
    for (items) |item, i| {
        if (item == wanted) return i;
    }
    return null;
}

const list = ["a", "b", "c"];
print(find(list, "b"), find(list, "z"), find(list, "z") orelse -1);
// out: 1 null -1
if (find(list, "c")) |at| print("found at", at);
// out: found at 2
if (find(list, "q")) |at| print(at) else print("missing");
// out: missing
const e = Enemy{ .name = "orc" };
const boss = Enemy{ .name = "boss", .target = e };
if (boss.target) |t| print(boss.name, "targets", t.name);
// out: boss targets orc
print(boss.target.?.name, e.target == null);
// out: orc true
var queue = [3, 2, 1];
while (queue.pop()) |x| print(x);
// out: 1
// out: 2
// out: 3
var maybe: ?int = null;
maybe = 5;
print(maybe.? + 1);
// out: 6

// A fallback that returns leaves the value's own path going on: no
// "never reached" warning for what follows.
fn firstPositive(xs: [int]) int {
    const found = xs.find(|x| x > 0) orelse return 0;
    const kept = if (found > 100) found else return found;
    return kept * 2;
}
print(firstPositive([-1, 5]), firstPositive([-2]), firstPositive([200]));
// out: 5 0 400
