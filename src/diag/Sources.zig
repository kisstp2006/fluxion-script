// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("fluxion_text");

const diag = @import("../diag.zig");
const FileId = diag.FileId;

const Sources = @This();

gpa: Allocator,
files: std.ArrayList(File) = .empty,

pub const File = struct {
    name: []const u8,
    text: []const u8,
    line_starts: std.ArrayList(u32) = .empty,
};

pub const Position = struct {
    line: u32,
    column: u32,
};

pub fn init(gpa: Allocator) Sources {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Sources) void {
    for (self.files.items) |*f| {
        self.gpa.free(f.name);
        self.gpa.free(f.text);
        f.line_starts.deinit(self.gpa);
    }
    self.files.deinit(self.gpa);
    self.* = undefined;
}

pub fn add(self: *Sources, file_name: []const u8, source: []const u8) Allocator.Error!FileId {
    const owned_name = try self.gpa.dupe(u8, file_name);
    errdefer self.gpa.free(owned_name);
    const owned_text = try self.gpa.dupe(u8, source);
    errdefer self.gpa.free(owned_text);
    try self.files.append(self.gpa, .{ .name = owned_name, .text = owned_text });
    return @enumFromInt(self.files.items.len - 1);
}

pub fn get(self: *const Sources, id: FileId) ?*const File {
    const i = @intFromEnum(id);
    if (id == .none or i >= self.files.items.len) return null;
    return &self.files.items[i];
}

pub fn name(self: *const Sources, id: FileId) []const u8 {
    return if (self.get(id)) |f| f.name else "<unknown>";
}

fn lines(self: *Sources, id: FileId) []const u32 {
    const f = &self.files.items[@intFromEnum(id)];
    if (f.line_starts.items.len == 0) {
        f.line_starts.append(self.gpa, 0) catch return &.{};
        for (f.text, 0..) |c, i| {
            if (c == '\n') f.line_starts.append(self.gpa, @intCast(i + 1)) catch {
                f.line_starts.clearRetainingCapacity();
                return &.{};
            };
        }
    }
    return f.line_starts.items;
}

/// One-based line and column, the column counted in characters as an editor
/// shows it.
pub fn position(self: *Sources, id: FileId, offset: u32) Position {
    const f = self.get(id) orelse return .{ .line = 0, .column = 0 };
    const at = @min(offset, f.text.len);
    const starts = self.lines(id);
    if (starts.len == 0) {
        const loc = text.Parser.init(f.text).locationAt(at);
        return .{ .line = @intCast(loc.line), .column = @intCast(loc.column) };
    }
    const index = lineIndex(starts, @intCast(at));
    var column: u32 = 1;
    var it: text.utf8.Iterator = .init(f.text[starts[index]..at]);
    while (it.nextLossy()) |_| column += 1;
    return .{ .line = @intCast(index + 1), .column = column };
}

fn lineIndex(starts: []const u32, offset: u32) usize {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= offset) lo = mid else hi = mid;
    }
    return lo;
}

/// The text of a one-based line, without its terminator.
pub fn line(self: *Sources, id: FileId, number: u32) []const u8 {
    const f = self.get(id) orelse return "";
    const starts = self.lines(id);
    if (number == 0 or number > starts.len) return "";
    const start = starts[number - 1];
    const end = if (number < starts.len) starts[number] - 1 else f.text.len;
    return std.mem.trimEnd(u8, f.text[start..end], "\r");
}

pub fn lineCount(self: *Sources, id: FileId) u32 {
    return @intCast(self.lines(id).len);
}

test "positions count lines from one and columns in characters" {
    var sources: Sources = .init(std.testing.allocator);
    defer sources.deinit();
    const id = try sources.add("a.flux", "var x = 1;\nvar é = 2;\n  x");
    try std.testing.expectEqual(Position{ .line = 1, .column = 1 }, sources.position(id, 0));
    try std.testing.expectEqual(Position{ .line = 2, .column = 6 }, sources.position(id, 17));
    try std.testing.expectEqual(Position{ .line = 3, .column = 3 }, sources.position(id, 25));
    try std.testing.expectEqualStrings("var é = 2;", sources.line(id, 2));
    try std.testing.expectEqualStrings("  x", sources.line(id, 3));
    try std.testing.expectEqual(@as(u32, 3), sources.lineCount(id));
}
