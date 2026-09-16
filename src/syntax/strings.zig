// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("fluxion_text");

const diag = @import("../diag.zig");

pub const Context = struct {
    arena: Allocator,
    file: diag.FileId,
    diags: *diag.Diagnostics,
};

fn bad(ctx: Context, start: usize, end: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    _ = try (try ctx.diags.err(.{ .file = ctx.file, .span = .{ .start = @intCast(start), .end = @intCast(end) } }, fmt, args))
        .help("the escapes are \\n \\t \\r \\0 \\\\ \\\" \\' \\{{ \\}} \\xNN and \\u{{NNNN}}", .{});
}

/// Decodes one escape at `raw[i]` (the byte after `\`), appending the
/// character to `out`. Returns how many bytes of `raw` it used.
pub fn escape(ctx: Context, raw: []const u8, i: usize, base: usize, out: *std.ArrayList(u8)) Allocator.Error!usize {
    if (i >= raw.len) {
        try bad(ctx, base + i - 1, base + i, "a `\\` needs a character after it", .{});
        return 0;
    }
    const c = raw[i];
    const simple: ?u8 = switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        '\\' => '\\',
        '"' => '"',
        '\'' => '\'',
        '{' => '{',
        '}' => '}',
        else => null,
    };
    if (simple) |byte| {
        try out.append(ctx.arena, byte);
        return 1;
    }
    switch (c) {
        'x' => {
            if (i + 2 < raw.len) {
                const hi = text.number.digitValue(raw[i + 1]);
                const lo = text.number.digitValue(raw[i + 2]);
                if (hi != null and lo != null and hi.? < 16 and lo.? < 16) {
                    try out.append(ctx.arena, hi.? * 16 + lo.?);
                    return 3;
                }
            }
            try bad(ctx, base + i - 1, base + @min(raw.len, i + 3), "`\\x` takes exactly two hex digits", .{});
            return @min(raw.len - i, 1);
        },
        'u' => {
            const close = if (i + 1 < raw.len and raw[i + 1] == '{') std.mem.indexOfScalarPos(u8, raw, i + 2, '}') else null;
            if (close) |end| {
                const digits = raw[i + 2 .. end];
                const value = std.fmt.parseInt(u21, digits, 16) catch null;
                if (value) |cp| {
                    var buf: [4]u8 = undefined;
                    if (digits.len > 0 and digits.len <= 6) {
                        if (std.unicode.utf8Encode(cp, &buf)) |len| {
                            try out.appendSlice(ctx.arena, buf[0..len]);
                            return end - i + 1;
                        } else |_| {}
                    }
                }
                try bad(ctx, base + i - 1, base + end + 1, "`\\u{{{s}}}` is not a character", .{digits});
                return end - i + 1;
            }
            try bad(ctx, base + i - 1, base + i + 1, "`\\u` is written `\\u{{1F600}}`", .{});
            return 1;
        },
        else => {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
            try bad(ctx, base + i - 1, base + @min(raw.len, i + len), "`\\{s}` is not an escape", .{raw[i..@min(raw.len, i + len)]});
            return @min(raw.len - i, len);
        },
    }
}

/// The characters of a string literal's body, escapes decoded. `base` is
/// where `raw` starts in the file, for the messages.
pub fn decode(ctx: Context, raw: []const u8, base: usize) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = try .initCapacity(ctx.arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            i += 1;
            i += try escape(ctx, raw, i, base, &out);
        } else {
            try out.append(ctx.arena, raw[i]);
            i += 1;
        }
    }
    return out.items;
}

/// A character literal's value, or null after reporting why it has none.
pub fn char(ctx: Context, raw: []const u8, base: usize) Allocator.Error!?i64 {
    const bytes = try decode(ctx, raw, base);
    if (bytes.len == 0) {
        _ = try ctx.diags.err(.{ .file = ctx.file, .span = .{ .start = @intCast(base - 1), .end = @intCast(base + raw.len + 1) } }, "a character literal needs one character", .{});
        return null;
    }
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch 1;
    const cp = std.unicode.utf8Decode(bytes[0..@min(bytes.len, len)]) catch bytes[0];
    if (len != bytes.len) {
        _ = try (try ctx.diags.err(.{ .file = ctx.file, .span = .{ .start = @intCast(base - 1), .end = @intCast(base + raw.len + 1) } }, "a character literal holds one character", .{}))
            .help("use double quotes for a string", .{});
        return null;
    }
    return cp;
}

/// Where the `}` closing the expression that starts at `raw[start]` is,
/// and the `:` before a format spec if there is one.
pub const Hole = struct { close: usize, colon: ?usize };

pub fn hole(raw: []const u8, start: usize) ?Hole {
    var depth: usize = 0;
    var colon: ?usize = null;
    var i = start;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '{', '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            '}' => {
                if (depth == 0) return .{ .close = i, .colon = colon };
                depth -= 1;
            },
            ':' => if (depth == 0 and colon == null) {
                colon = i;
            },
            '"' => {
                i += 1;
                while (i < raw.len and raw[i] != '"') : (i += 1) {
                    if (raw[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    return null;
}

const testing = std.testing;

fn testCtx(diags: *diag.Diagnostics, arena: Allocator) Context {
    return .{ .arena = arena, .file = @enumFromInt(0), .diags = diags };
}

test "escapes decode, and a string without any is not copied" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: diag.Diagnostics = .init(testing.allocator);
    defer diags.deinit();
    const ctx = testCtx(&diags, arena.allocator());
    const plain = "no escapes";
    try testing.expectEqual(plain.ptr, (try decode(ctx, plain, 0)).ptr);
    try testing.expectEqualStrings("a\nb\t\"c\" \\ \x41 \u{1F600} {x}", try decode(ctx, "a\\nb\\t\\\"c\\\" \\\\ \\x41 \\u{1F600} \\{x\\}", 0));
    try testing.expect(!diags.failed());
}

test "a bad escape is reported where it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: diag.Diagnostics = .init(testing.allocator);
    defer diags.deinit();
    _ = try decode(testCtx(&diags, arena.allocator()), "ok \\q \\xZ1 \\u{110000}", 10);
    try testing.expectEqual(@as(u32, 3), diags.errors);
    try testing.expectEqualStrings("`\\q` is not an escape", diags.items.items[0].message);
    try testing.expectEqual(@as(u32, 13), diags.items.items[0].primary().?.span.start);
}

test "a character literal is one code point" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: diag.Diagnostics = .init(testing.allocator);
    defer diags.deinit();
    const ctx = testCtx(&diags, arena.allocator());
    try testing.expectEqual(@as(?i64, 'a'), try char(ctx, "a", 1));
    try testing.expectEqual(@as(?i64, 0xE9), try char(ctx, "é", 1));
    try testing.expectEqual(@as(?i64, '\n'), try char(ctx, "\\n", 1));
    try testing.expectEqual(@as(?i64, null), try char(ctx, "ab", 1));
}

test "a hole ends at its own brace, past nested ones and strings" {
    const raw = "x {m[\"}\"]:>8} y {a{b}c}";
    const first = hole(raw, 3).?;
    try testing.expectEqual(@as(usize, 12), first.close);
    try testing.expectEqual(@as(?usize, 9), first.colon);
    const second = hole(raw, 17).?;
    try testing.expectEqual(@as(usize, 22), second.close);
    try testing.expectEqual(@as(?usize, null), second.colon);
}
