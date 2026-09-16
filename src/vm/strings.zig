// SPDX-License-Identifier: BSD-2-Clause

//! Strings are made once for each short text: the same short text is the
//! same object, so comparing names and looking up fields compares pointers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const hashing = @import("fluxion_hash");

const object = @import("object.zig");
const String = object.String;

/// Longer strings are made fresh each time; they are rarely names.
pub const intern_limit = 40;

pub fn hashBytes(bytes: []const u8) u32 {
    const h = hashing.hashBytes(bytes);
    return @truncate(h ^ (h >> 32));
}

pub fn countChars(bytes: []const u8) u32 {
    var n: u32 = 0;
    for (bytes) |c| n += @intFromBool(c & 0xC0 != 0x80);
    return n;
}

const Context = struct {
    pub fn hash(_: Context, s: *String) u32 {
        return s.hash;
    }
    pub fn eql(_: Context, a: *String, b: *String, _: usize) bool {
        return a == b;
    }
};

const BytesContext = struct {
    hash_value: u32,
    pub fn hash(c: BytesContext, _: []const u8) u32 {
        return c.hash_value;
    }
    pub fn eql(_: BytesContext, bytes: []const u8, s: *String, _: usize) bool {
        return std.mem.eql(u8, bytes, s.bytes());
    }
};

pub const Interned = struct {
    set: std.ArrayHashMapUnmanaged(*String, void, Context, false) = .empty,

    pub fn deinit(t: *Interned, gpa: Allocator) void {
        t.set.deinit(gpa);
    }

    pub fn find(t: *const Interned, bytes: []const u8, hash: u32) ?*String {
        const i = t.set.getIndexAdapted(bytes, BytesContext{ .hash_value = hash }) orelse return null;
        return t.set.keys()[i];
    }

    pub fn add(t: *Interned, gpa: Allocator, s: *String) Allocator.Error!void {
        try t.set.putContext(gpa, s, {}, .{});
    }

    pub fn remove(t: *Interned, s: *String) void {
        _ = t.set.swapRemoveContext(s, .{});
    }

    pub fn count(t: *const Interned) usize {
        return t.set.count();
    }
};

test "hashes and character counts" {
    try std.testing.expectEqual(hashBytes("player"), hashBytes("player"));
    try std.testing.expect(hashBytes("player") != hashBytes("players"));
    try std.testing.expectEqual(@as(u32, 5), countChars("héllo"));
    try std.testing.expectEqual(@as(u32, 1), countChars("\u{1F600}"));
}
