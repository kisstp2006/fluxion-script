struct Inventory {
    var items: [string];

    fn take(self, slot: int) string {
        return self.items[slot];
    }
}

fn open(inv: Inventory) string {
    return inv.take(5);
}

const inv = Inventory{ .items = ["sword"] };
print("before");
// out: before
print(open(inv));
// panic: index 5 is out of bounds for a list of length 1
print("never");
