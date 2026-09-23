// SPDX-License-Identifier: BSD-2-Clause

//! The hash table behind a map: entries kept in the order they were added,
//! as Python's dictionaries keep them, found through an
//! index of slots. A float key with a whole value is stored as the int, so
//! `m[1]` and `m[1.0]` are one entry.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Value = @import("value.zig").Value;
const object = @import("object.zig");

pub const Entry = struct {
    key: Value,
    value: Value,
    hash: u32,
};

const empty_slot: u32 = 0;
const deleted_slot: u32 = std.math.maxInt(u32);

pub const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    slots: []u32 = &.{},
    live: u32 = 0,
    version: u32 = 0,

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.entries.deinit(gpa);
        if (t.slots.len > 0) gpa.free(t.slots);
        t.* = .{};
    }

    pub fn count(t: *const Table) usize {
        return t.live;
    }

    pub const KeyError = error{NanKey};

    /// The key as the table stores it.
    pub fn normalize(key: Value) KeyError!Value {
        if (key.tag != .float) return key;
        const f = key.asFloat();
        if (std.math.isNan(f)) return error.NanKey;
        if (f == @trunc(f) and f >= -9.2e18 and f <= 9.2e18) return .int(@intFromFloat(f));
        return key;
    }

    pub fn hashOf(key: Value) u32 {
        return switch (key.tag) {
            .string => key.as(object.String).hash,
            .float => mix(key.raw),
            .vec2, .vec3 => mix(key.raw ^ (@as(u64, key.extra) << 32 | key.extra)),
            .enum_value => mix(key.raw +% key.extra),
            else => mix(key.raw ^ @intFromEnum(key.tag)),
        };
    }

    fn mix(x: u64) u32 {
        var z = x +% 0x9E3779B97F4A7C15;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return @truncate(z ^ (z >> 31));
    }

    pub fn keysEqual(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .string => a.as(object.String).eql(b.as(object.String)),
            .vec3 => a.raw == b.raw and a.extra == b.extra,
            .enum_value => a.raw == b.raw and a.extra == b.extra,
            else => a.raw == b.raw,
        };
    }

    fn find(t: *const Table, key: Value, hash: u32) ?u32 {
        if (t.slots.len == 0) return null;
        const mask = t.slots.len - 1;
        var i = hash & mask;
        while (true) : (i = (i + 1) & mask) {
            const slot = t.slots[i];
            if (slot == empty_slot) return null;
            if (slot == deleted_slot) continue;
            const e = &t.entries.items[slot - 1];
            if (e.hash == hash and keysEqual(e.key, key)) return slot - 1;
        }
    }

    /// Where `key` is, as an index into `entries`, or null.
    pub fn indexOf(t: *const Table, key: Value) ?u32 {
        const k = normalize(key) catch return null;
        return t.find(k, hashOf(k));
    }

    pub fn get(t: *const Table, key: Value) ?Value {
        const i = t.indexOf(key) orelse return null;
        return t.entries.items[i].value;
    }

    pub fn getPtr(t: *Table, key: Value) ?*Value {
        const i = t.indexOf(key) orelse return null;
        return &t.entries.items[i].value;
    }

    pub fn put(t: *Table, gpa: Allocator, key: Value, value: Value) (Allocator.Error || KeyError)!void {
        const k = try normalize(key);
        const hash = hashOf(k);
        if (t.find(k, hash)) |i| {
            t.entries.items[i].value = value;
            return;
        }
        try t.reserve(gpa, t.entries.items.len + 1);
        try t.entries.append(gpa, .{ .key = k, .value = value, .hash = hash });
        t.insertSlot(hash, @intCast(t.entries.items.len));
        t.live += 1;
    }

    pub fn remove(t: *Table, key: Value) bool {
        const k = normalize(key) catch return false;
        const hash = hashOf(k);
        if (t.slots.len == 0) return false;
        const mask = t.slots.len - 1;
        var i = hash & mask;
        while (true) : (i = (i + 1) & mask) {
            const slot = t.slots[i];
            if (slot == empty_slot) return false;
            if (slot == deleted_slot) continue;
            const e = &t.entries.items[slot - 1];
            if (e.hash == hash and keysEqual(e.key, k)) {
                t.slots[i] = deleted_slot;
                e.key = .undef;
                e.value = .null;
                t.live -= 1;
                return true;
            }
        }
    }

    pub fn clear(t: *Table) void {
        t.entries.clearRetainingCapacity();
        @memset(t.slots, empty_slot);
        t.live = 0;
        t.version +%= 1;
    }

    /// The index made again after keys changed in place, as when a reload
    /// renumbers an enum's members. A key that now equals an earlier one
    /// goes, with its value.
    pub fn rehash(t: *Table) void {
        if (t.slots.len == 0) return;
        @memset(t.slots, empty_slot);
        for (t.entries.items, 1..) |*e, n| {
            if (e.key.tag == .undefined) continue;
            e.hash = hashOf(e.key);
            if (t.find(e.key, e.hash) != null) {
                e.key = .undef;
                e.value = .null;
                t.live -= 1;
                continue;
            }
            t.insertSlot(e.hash, @intCast(n));
        }
        t.version +%= 1;
    }

    fn insertSlot(t: *Table, hash: u32, slot: u32) void {
        const mask = t.slots.len - 1;
        var i = hash & mask;
        while (t.slots[i] != empty_slot and t.slots[i] != deleted_slot) i = (i + 1) & mask;
        t.slots[i] = slot;
    }

    /// Room for `wanted` entries: the index is kept under three quarters
    /// full, and removed entries are dropped when it is rebuilt.
    fn reserve(t: *Table, gpa: Allocator, wanted: usize) Allocator.Error!void {
        if (wanted * 4 <= t.slots.len * 3) return;
        if (t.live < t.entries.items.len) {
            var kept: usize = 0;
            for (t.entries.items) |e| {
                if (e.key.tag == .undefined) continue;
                t.entries.items[kept] = e;
                kept += 1;
            }
            t.entries.shrinkRetainingCapacity(kept);
            t.version +%= 1;
        }
        var size: usize = @max(8, t.slots.len);
        while ((t.live + 1) * 4 > size * 3) size *= 2;
        if (size != t.slots.len) {
            const fresh = try gpa.alloc(u32, size);
            if (t.slots.len > 0) gpa.free(t.slots);
            t.slots = fresh;
        }
        @memset(t.slots, empty_slot);
        for (t.entries.items, 1..) |e, n| t.insertSlot(e.hash, @intCast(n));
    }

    pub const Iterator = struct {
        table: *const Table,
        index: usize = 0,

        pub fn next(it: *Iterator) ?*const Entry {
            while (it.index < it.table.entries.items.len) {
                const e = &it.table.entries.items[it.index];
                it.index += 1;
                if (e.key.tag != .undefined) return e;
            }
            return null;
        }
    };

    pub fn iterator(t: *const Table) Iterator {
        return .{ .table = t };
    }
};

const testing = std.testing;

test "entries stay in the order they were added, and removal keeps it" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    for (0..100) |i| try t.put(testing.allocator, .int(@intCast(i * 7)), .int(@intCast(i)));
    try testing.expectEqual(@as(usize, 100), t.count());
    for (0..100) |i| try testing.expectEqual(@as(i64, @intCast(i)), t.get(.int(@intCast(i * 7))).?.asInt());
    for (0..50) |i| try testing.expect(t.remove(.int(@intCast(i * 14))));
    try testing.expectEqual(@as(usize, 50), t.count());
    var it = t.iterator();
    var previous: i64 = -1;
    while (it.next()) |e| {
        try testing.expect(e.value.asInt() > previous);
        try testing.expect(@mod(e.key.asInt(), 14) != 0);
        previous = e.value.asInt();
    }
    for (0..200) |i| try t.put(testing.allocator, .int(@intCast(1000 + i)), .null);
    try testing.expectEqual(@as(usize, 250), t.count());
    try testing.expect(t.get(.int(0)) == null);
    try testing.expect(t.get(.int(7)) != null);
}

test "a whole float is the int key, and NaN is refused" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    try t.put(testing.allocator, .int(1), .int(10));
    try t.put(testing.allocator, .float(1.0), .int(20));
    try testing.expectEqual(@as(usize, 1), t.count());
    try testing.expectEqual(@as(i64, 20), t.get(.int(1)).?.asInt());
    try testing.expectError(error.NanKey, t.put(testing.allocator, .float(std.math.nan(f64)), .null));
    try t.put(testing.allocator, .float(1.5), .int(3));
    try testing.expectEqual(@as(i64, 3), t.get(.float(1.5)).?.asInt());
}
