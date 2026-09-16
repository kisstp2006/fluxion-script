const words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"];
var counts: [string: int] = {};
var parts: [string] = [];
for (0..400000) |i| {
    const w = words[i % 8];
    const key = f"{w}{i % 100}";
    counts[key] = counts.get(key, 0).? + 1;
    if (i % 1000 == 0) parts.push(key.upper());
}
var total = 0;
for (counts) |_, v| total += v;
print(counts.len, total, parts.join(",").len);
