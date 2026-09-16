// An application in a page: read an inventory as JSON - from the file
// named on the command line, or the one written below - check each entry,
// and report on what is there.
//
//     flux run examples/scripts/inventory.flux [inventory.json]

const json = @import("json");
const os = @import("os");

struct Item {
    var name: string = "";
    var weight: float = 0;
    var count: int = 1;

    fn total(self) float {
        return self.weight * float(self.count);
    }
}

const sample =
    \\[
    \\  {"name": "rope", "weight": 1.5, "count": 2},
    \\  {"name": "lantern", "weight": 2.25},
    \\  {"name": "rations", "weight": 0.5, "count": 6},
    \\  {"name": "map", "weight": 0.1}
    \\]
;

/// One entry of the file as an item, or an error saying what is wrong
/// with it and where.
fn parseItem(entry: any, at: int) !Item {
    if (typeof(entry) != "map") return error.BadItem(f"entry {at} is not an object");
    const name = entry.get("name") orelse return error.BadItem(f"entry {at} has no name");
    const weight = float(entry.get("weight", 0)) catch return error.BadItem(f"{name}: the weight is not a number");
    const count = int(entry.get("count", 1)) catch return error.BadItem(f"{name}: the count is not a number");
    if (count < 1) return error.BadItem(f"{name}: a count of {count}");
    return Item{ .name = str(name), .weight = weight, .count = count };
}

fn load() ![Item] {
    const text = if (os.args.len > 1) try os.read_file(os.args[1]) else sample;
    const data = try json.parse(text);
    var items: [Item] = [];
    for (data) |entry, i| items.push(try parseItem(entry, i));
    return items;
}

fn main() {
    const items = load() catch |e| {
        print(f"cannot read the inventory: {e.message orelse e.name}");
        return;
    };
    items.sort_by(|a, b| a.total() > b.total());
    const weight = items.map(|i| i.total()).sum();
    print(f"{items.len} kinds of thing, {weight:.2} kg in all");
    for (items) |item| {
        print(f"  {item.name:<10} {item.count:>3} x {item.weight:.2} kg");
    }
    print(f"the heaviest is the {items[0].name}");
    const light = items.filter(|i| i.weight < 1.0).map(|i| i.name);
    const names = light.join(", ");
    print(f"light enough to throw: {names}");
}

main();
