// A native that calls back into the script - map, sort_by, a signal's
// emit, a struct's computed defaults - pushes frames on the same line of
// execution, and may move where frames are kept. Done at every depth, one
// of them is where that happens.
struct Counter {
    var ticks: [int] = [];
    signal ticked(n: int);
}

fn deep(n: int) int {
    if (n == 0) {
        const c = Counter{};
        c.ticked.connect(|v| {
            c.ticks.push(v);
        });
        c.ticked.emit(1);
        return [1, 2, 3].map(|x| x * 2).sum() + c.ticks.len;
    }
    return deep(n - 1);
}

var total = 0;
for (0..300) |d| total += deep(d);
print(total);
// out: 3900
