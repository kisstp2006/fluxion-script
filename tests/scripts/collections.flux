var xs = [5, 3, 8, 1];
xs.push(4);
xs.sort();
print(xs, xs.len, xs[0], xs[-1]);
// out: [1, 3, 4, 5, 8] 5 1 8
print(xs.map(|x| x * 10), xs.filter(|x| x % 2 == 0), xs.reduce(|acc, x| acc + x, 0));
// out: [10, 30, 40, 50, 80] [4, 8] 21
print(xs.contains(4), xs.index_of(5), xs.index_of(99), xs.any(|x| x > 7), xs.all(|x| x > 0));
// out: true 3 null true true
print(xs[1..3], xs.reversed(), xs.first(), xs.sum());
// out: [3, 4] [8, 5, 4, 3, 1] 1 21
xs.insert(0, 0);
_ = xs.remove(1);
print(xs, [1, 2] + [3], [[1], [2]]);
// out: [0, 3, 4, 5, 8] [1, 2, 3] [[1], [2]]

struct Item {
    var name: string;
    var weight: float;
}
var bag: [Item] = [Item{ .name = "sword", .weight = 3.5 }, Item{ .name = "apple", .weight = 0.2 }];
bag.sort_by(|a, b| a.weight < b.weight);
print(bag.map(|i| i.name).join(", "));
// out: apple, sword
print(bag.find(|i| i.weight > 1.0).?.name);
// out: sword

var m: [string: int] = {};
m["hp"] = 10;
m["mp"] = 5;
m["hp"] += 1;
print(m, m.len, m["hp"], m.get("xp"), m.get("xp", 0), "mp" in m);
// out: {"hp": 11, "mp": 5} 2 11 null 0 true
print(m.keys(), m.values());
// out: ["hp", "mp"] [11, 5]
_ = m.remove("hp");
print(m, [1, 2] == [1, 2], {"a": 1} == {"a": 1});
// out: {"mp": 5} true true
const words = "the quick  brown fox".split();
print(words, "a,b,,c".split(","), " pad ".trim(), "Hi".upper(), "x".repeat(3));
// out: ["the", "quick", "brown", "fox"] ["a", "b", "", "c"] pad HI xxx
print("hello world".replace("o", "0"), "abc".contains("b"), "abc".find("c"), "héllo".chars());
// out: hell0 w0rld true 2 ["h", "é", "l", "l", "o"]
print(range(3), range(1, 7, 2), min(3, 1, 2), max([4, 9, 2]), abs(-5), clamp(15, 0, 10));
// out: [0, 1, 2] [1, 3, 5] 1 9 5 10
