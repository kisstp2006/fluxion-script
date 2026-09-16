// SPDX-License-Identifier: BSD-2-Clause

//! Where each line of a text starts: to turn a byte offset into the line
//! and column the Language Server Protocol counts in, and back. The
//! protocol counts columns in UTF-16 code units unless the client takes
//! UTF-8, when they are bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Lines = @This();

pub const Encoding = enum { utf8, utf16 };

pub const Position = struct {
    line: u32,
    character: u32,
};

text: []const u8,
starts: []u32,
encoding: Encoding,

pub fn init(gpa: Allocator, text: []const u8, encoding: Encoding) Allocator.Error!Lines {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);
    for (text, 0..) |c, i| if (c == '\n') try starts.append(gpa, @intCast(i + 1));
    return .{ .text = text, .starts = try starts.toOwnedSlice(gpa), .encoding = encoding };
}

pub fn deinit(l: *Lines, gpa: Allocator) void {
    gpa.free(l.starts);
    l.* = undefined;
}

fn lineOf(l: *const Lines, byte: u32) usize {
    var lo: usize = 0;
    var hi = l.starts.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (l.starts[mid] <= byte) lo = mid else hi = mid;
    }
    return lo;
}

fn lineEnd(l: *const Lines, line: usize) u32 {
    if (line + 1 < l.starts.len) return l.starts[line + 1] - 1;
    return @intCast(l.text.len);
}

/// How many columns `text[from..to]` takes.
pub fn units(l: *const Lines, from: u32, to: u32) u32 {
    if (l.encoding == .utf8) return to - from;
    var n: u32 = 0;
    var i: usize = from;
    while (i < to) {
        const len = std.unicode.utf8ByteSequenceLength(l.text[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

pub fn position(l: *const Lines, byte: u32) Position {
    const at = @min(byte, @as(u32, @intCast(l.text.len)));
    const line = l.lineOf(at);
    return .{ .line = @intCast(line), .character = l.units(l.starts[line], at) };
}

/// The byte offset of a position; past the end of its line is the end of
/// it, and past the last line the end of the text.
pub fn offset(l: *const Lines, pos: Position) u32 {
    if (pos.line >= l.starts.len) return @intCast(l.text.len);
    var i: u32 = l.starts[pos.line];
    const end = l.lineEnd(pos.line);
    var n: u32 = 0;
    while (i < end and n < pos.character) {
        const len: u32 = std.unicode.utf8ByteSequenceLength(l.text[i]) catch 1;
        n += if (l.encoding == .utf8) len else if (len == 4) 2 else 1;
        i += len;
    }
    return @min(i, end);
}

test "offsets and positions agree, in UTF-16 and in UTF-8" {
    const text = "var a = 1;\nvar \u{e9} = \"\u{1F600}x\";\n";
    var l: Lines = try .init(std.testing.allocator, text, .utf16);
    defer l.deinit(std.testing.allocator);
    const x: u32 = @intCast(std.mem.indexOfScalar(u8, text, 'x').?);
    // `é` is one unit, the emoji two.
    try std.testing.expectEqual(Position{ .line = 1, .character = 11 }, l.position(x));
    try std.testing.expectEqual(x, l.offset(.{ .line = 1, .character = 11 }));
    try std.testing.expectEqual(Position{ .line = 0, .character = 4 }, l.position(4));
    try std.testing.expectEqual(@as(u32, 10), l.offset(.{ .line = 0, .character = 99 }));
    try std.testing.expectEqual(@as(u32, @intCast(text.len)), l.offset(.{ .line = 9, .character = 0 }));
    l.encoding = .utf8;
    try std.testing.expectEqual(Position{ .line = 1, .character = x - 11 }, l.position(x));
}
