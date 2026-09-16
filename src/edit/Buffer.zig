// SPDX-License-Identifier: BSD-2-Clause

//! The text being edited: its bytes, where each line starts, the caret and
//! the other end of the selection, and the changes that can be undone.
//! Offsets are bytes; columns are characters. Typing a word is one undo, as
//! is deleting one, and anything else is one each.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Buffer = @This();

pub const indent_width = 4;

gpa: Allocator,
text: std.ArrayList(u8) = .empty,
/// Where each line starts.
lines: std.ArrayList(u32) = .empty,
cursor: u32 = 0,
/// The other end of the selection: the caret's own offset when nothing is
/// selected.
anchor: u32 = 0,
/// The column up and down keep to across shorter lines.
goal: ?u32 = null,
undos: std.ArrayList(State) = .empty,
redos: std.ArrayList(State) = .empty,
last: Change = .none,
/// Counts every change, so what was made from the text can tell it is old.
version: u64 = 0,
saved: u64 = 0,

const State = struct { text: []u8, cursor: u32, anchor: u32 };
const Change = enum { none, typing, deleting, other };
const max_undo = 400;

pub fn init(gpa: Allocator, text: []const u8) Allocator.Error!Buffer {
    var b: Buffer = .{ .gpa = gpa };
    try b.setText(text);
    return b;
}

pub fn deinit(b: *Buffer) void {
    b.clearHistory();
    b.undos.deinit(b.gpa);
    b.redos.deinit(b.gpa);
    b.text.deinit(b.gpa);
    b.lines.deinit(b.gpa);
}

fn clearHistory(b: *Buffer) void {
    for (b.undos.items) |s| b.gpa.free(s.text);
    for (b.redos.items) |s| b.gpa.free(s.text);
    b.undos.clearRetainingCapacity();
    b.redos.clearRetainingCapacity();
}

/// New text, as a file just opened: tabs as spaces, `\r\n` as `\n`, and no
/// history.
pub fn setText(b: *Buffer, text: []const u8) Allocator.Error!void {
    b.clearHistory();
    b.text.clearRetainingCapacity();
    for (text) |c| switch (c) {
        '\r' => {},
        '\t' => try b.text.appendNTimes(b.gpa, ' ', indent_width),
        else => try b.text.append(b.gpa, c),
    };
    b.cursor = 0;
    b.anchor = 0;
    b.goal = null;
    b.last = .none;
    b.version += 1;
    b.saved = b.version;
    try b.reindex();
}

pub fn modified(b: *const Buffer) bool {
    return b.version != b.saved;
}

fn reindex(b: *Buffer) Allocator.Error!void {
    b.lines.clearRetainingCapacity();
    try b.lines.append(b.gpa, 0);
    for (b.text.items, 0..) |c, i| if (c == '\n') try b.lines.append(b.gpa, @intCast(i + 1));
}

// ---------------------------------------------------------------------------
// Lines and columns

pub fn len(b: *const Buffer) u32 {
    return @intCast(b.text.items.len);
}

pub fn lineCount(b: *const Buffer) u32 {
    return @intCast(b.lines.items.len);
}

pub fn lineStart(b: *const Buffer, line: u32) u32 {
    return b.lines.items[@min(line, b.lineCount() - 1)];
}

/// Where the line ends, before its `\n`.
pub fn lineEnd(b: *const Buffer, line: u32) u32 {
    if (line + 1 < b.lineCount()) return b.lines.items[line + 1] - 1;
    return b.len();
}

pub fn lineText(b: *const Buffer, line: u32) []const u8 {
    return b.text.items[b.lineStart(line)..b.lineEnd(line)];
}

pub fn lineOf(b: *const Buffer, offset: u32) u32 {
    var lo: usize = 0;
    var hi = b.lines.items.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (b.lines.items[mid] <= offset) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

fn isContinuation(c: u8) bool {
    return c & 0xC0 == 0x80;
}

/// Characters from the start of its line.
pub fn column(b: *const Buffer, offset: u32) u32 {
    var n: u32 = 0;
    for (b.text.items[b.lineStart(b.lineOf(offset))..offset]) |c| {
        if (!isContinuation(c)) n += 1;
    }
    return n;
}

/// The offset of a column on a line, or the line's end if it is shorter.
pub fn offsetAt(b: *const Buffer, line: u32, col: u32) u32 {
    var at = b.lineStart(line);
    const end = b.lineEnd(line);
    var n: u32 = 0;
    while (at < end and n < col) {
        at += 1;
        while (at < end and isContinuation(b.text.items[at])) at += 1;
        n += 1;
    }
    return at;
}

/// The selection, start first, or null when there is none.
pub fn selection(b: *const Buffer) ?[2]u32 {
    if (b.cursor == b.anchor) return null;
    return .{ @min(b.cursor, b.anchor), @max(b.cursor, b.anchor) };
}

pub fn selectedText(b: *const Buffer) []const u8 {
    const s = b.selection() orelse return "";
    return b.text.items[s[0]..s[1]];
}

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Where the word ending at `offset` starts.
pub fn wordStart(b: *const Buffer, offset: u32) u32 {
    var at = offset;
    while (at > 0 and isWordChar(b.text.items[at - 1])) at -= 1;
    return at;
}

pub fn wordEnd(b: *const Buffer, offset: u32) u32 {
    var at = offset;
    while (at < b.len() and isWordChar(b.text.items[at])) at += 1;
    return at;
}

fn indentOf(b: *const Buffer, line: u32) u32 {
    var n: u32 = 0;
    for (b.lineText(line)) |c| {
        if (c != ' ') break;
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Changes

fn remember(b: *Buffer, kind: Change) Allocator.Error!void {
    b.goal = null;
    for (b.redos.items) |s| b.gpa.free(s.text);
    b.redos.clearRetainingCapacity();
    if (kind != .other and kind == b.last) return;
    b.last = kind;
    if (b.undos.items.len == max_undo) {
        b.gpa.free(b.undos.orderedRemove(0).text);
    }
    try b.undos.append(b.gpa, .{ .text = try b.gpa.dupe(u8, b.text.items), .cursor = b.cursor, .anchor = b.anchor });
}

/// `text[start..end]` becomes `bytes`, the caret after them.
pub fn replace(b: *Buffer, start: u32, end: u32, bytes: []const u8, kind: Change) Allocator.Error!void {
    try b.remember(kind);
    try b.text.replaceRange(b.gpa, start, end - start, bytes);
    b.cursor = start + @as(u32, @intCast(bytes.len));
    b.anchor = b.cursor;
    b.version += 1;
    try b.reindex();
}

/// Types `bytes` over the selection, or at the caret.
pub fn insert(b: *Buffer, bytes: []const u8) Allocator.Error!void {
    const s = b.selection() orelse [2]u32{ b.cursor, b.cursor };
    const word = bytes.len == 1 and isWordChar(bytes[0]) and b.selection() == null;
    try b.replace(s[0], s[1], bytes, if (word) .typing else .other);
}

/// Types a character, closing a bracket or a quote it opens, and stepping
/// over the closer when it is what comes next.
pub fn typeChar(b: *Buffer, c: u8) Allocator.Error!void {
    const next: u8 = if (b.cursor < b.len()) b.text.items[b.cursor] else 0;
    if (b.selection() == null and (c == ')' or c == ']' or c == '}' or c == '"') and next == c) {
        b.moveTo(b.cursor + 1, false);
        return;
    }
    const closer: u8 = switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        else => 0,
    };
    const opens_here = next == 0 or next == ' ' or next == '\n' or next == ')' or next == ']' or next == '}' or next == ',' or next == ';';
    if (closer != 0 and b.selection() == null and opens_here and !(c == '"' and b.cursor > 0 and isWordChar(b.text.items[b.cursor - 1]))) {
        try b.replace(b.cursor, b.cursor, &.{ c, closer }, .other);
        b.moveTo(b.cursor - 1, false);
        return;
    }
    try b.insert(&.{c});
}

pub fn backspace(b: *Buffer) Allocator.Error!void {
    if (b.selection()) |s| return b.replace(s[0], s[1], "", .deleting);
    if (b.cursor == 0) return;
    const start = b.lineStart(b.lineOf(b.cursor));
    const before = b.text.items[start..b.cursor];
    // In the indentation, back to the tab stop before.
    if (before.len > 0 and std.mem.trimStart(u8, before, " ").len == 0) {
        const to = (before.len - 1) / indent_width * indent_width;
        return b.replace(start + @as(u32, @intCast(to)), b.cursor, "", .deleting);
    }
    // Between a pair it just opened: both go.
    const prev = b.text.items[b.cursor - 1];
    const next: u8 = if (b.cursor < b.len()) b.text.items[b.cursor] else 0;
    if ((prev == '(' and next == ')') or (prev == '[' and next == ']') or (prev == '{' and next == '}') or (prev == '"' and next == '"')) {
        return b.replace(b.cursor - 1, b.cursor + 1, "", .deleting);
    }
    var at = b.cursor - 1;
    while (at > 0 and isContinuation(b.text.items[at])) at -= 1;
    try b.replace(at, b.cursor, "", .deleting);
}

pub fn delete(b: *Buffer) Allocator.Error!void {
    if (b.selection()) |s| return b.replace(s[0], s[1], "", .deleting);
    if (b.cursor >= b.len()) return;
    var at = b.cursor + 1;
    while (at < b.len() and isContinuation(b.text.items[at])) at += 1;
    try b.replace(b.cursor, at, "", .deleting);
}

pub fn deleteWord(b: *Buffer, forward: bool) Allocator.Error!void {
    if (b.selection() != null) return if (forward) b.delete() else b.backspace();
    const to = if (forward) b.wordRight(b.cursor) else b.wordLeft(b.cursor);
    try b.replace(@min(to, b.cursor), @max(to, b.cursor), "", .other);
}

/// A line break, and the indentation the next line wants: the line's own,
/// one more after an opening bracket, and a closing one moved down a line.
pub fn newline(b: *Buffer) Allocator.Error!void {
    const line = b.lineOf(b.cursor);
    var indent = b.indentOf(line);
    const prev: u8 = if (b.cursor > b.lineStart(line)) b.text.items[b.cursor - 1] else 0;
    const next: u8 = if (b.cursor < b.len()) b.text.items[b.cursor] else 0;
    const opens = prev == '{' or prev == '(' or prev == '[';
    if (opens) indent += indent_width;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(b.gpa);
    try bytes.append(b.gpa, '\n');
    try bytes.appendNTimes(b.gpa, ' ', indent);
    const caret = bytes.items.len;
    if (opens and (next == '}' or next == ')' or next == ']')) {
        try bytes.append(b.gpa, '\n');
        try bytes.appendNTimes(b.gpa, ' ', indent - indent_width);
    }
    const s = b.selection() orelse [2]u32{ b.cursor, b.cursor };
    try b.replace(s[0], s[1], bytes.items, .other);
    b.moveTo(s[0] + @as(u32, @intCast(caret)), false);
}

/// Tab: spaces to the next stop, or the selected lines indented.
pub fn tab(b: *Buffer) Allocator.Error!void {
    if (b.selection()) |s| if (b.lineOf(s[0]) != b.lineOf(s[1])) return b.shiftLines(false);
    const col = b.column(b.cursor);
    const spaces = indent_width - col % indent_width;
    try b.insert(("    ")[0..spaces]);
}

/// The selected lines, or the caret's, moved a stop right or left.
pub fn shiftLines(b: *Buffer, left: bool) Allocator.Error!void {
    const s = b.selection() orelse [2]u32{ b.cursor, b.cursor };
    const first = b.lineOf(s[0]);
    var last = b.lineOf(s[1]);
    if (last > first and s[1] == b.lineStart(last)) last -= 1;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(b.gpa);
    var line = first;
    while (line <= last) : (line += 1) {
        const text = b.lineText(line);
        if (left) {
            const n = @min(b.indentOf(line), indent_width);
            try out.appendSlice(b.gpa, text[n..]);
        } else {
            if (text.len > 0) try out.appendNTimes(b.gpa, ' ', indent_width);
            try out.appendSlice(b.gpa, text);
        }
        if (line < last) try out.append(b.gpa, '\n');
    }
    const start = b.lineStart(first);
    try b.replace(start, b.lineEnd(last), out.items, .other);
    b.anchor = start;
    b.cursor = start + @as(u32, @intCast(out.items.len));
}

/// `//` put before the selected lines, or taken off when each has one.
pub fn toggleComment(b: *Buffer) Allocator.Error!void {
    const s = b.selection() orelse [2]u32{ b.cursor, b.cursor };
    const first = b.lineOf(s[0]);
    var last = b.lineOf(s[1]);
    if (last > first and s[1] == b.lineStart(last)) last -= 1;
    var all = true;
    var least: u32 = std.math.maxInt(u32);
    var line = first;
    while (line <= last) : (line += 1) {
        const text = b.lineText(line);
        if (std.mem.trim(u8, text, " ").len == 0) continue;
        least = @min(least, b.indentOf(line));
        if (!std.mem.startsWith(u8, text[b.indentOf(line)..], "//")) all = false;
    }
    if (least == std.math.maxInt(u32)) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(b.gpa);
    line = first;
    while (line <= last) : (line += 1) {
        const text = b.lineText(line);
        if (std.mem.trim(u8, text, " ").len == 0) {
            try out.appendSlice(b.gpa, text);
        } else if (all) {
            const at = b.indentOf(line);
            var rest = text[at + 2 ..];
            if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
            try out.appendSlice(b.gpa, text[0..at]);
            try out.appendSlice(b.gpa, rest);
        } else {
            try out.appendSlice(b.gpa, text[0..least]);
            try out.appendSlice(b.gpa, "// ");
            try out.appendSlice(b.gpa, text[least..]);
        }
        if (line < last) try out.append(b.gpa, '\n');
    }
    const start = b.lineStart(first);
    try b.replace(start, b.lineEnd(last), out.items, .other);
    b.anchor = start;
    b.cursor = start + @as(u32, @intCast(out.items.len));
}

pub fn undo(b: *Buffer) Allocator.Error!void {
    try b.step(&b.undos, &b.redos);
}

pub fn redo(b: *Buffer) Allocator.Error!void {
    try b.step(&b.redos, &b.undos);
}

fn step(b: *Buffer, from: *std.ArrayList(State), to: *std.ArrayList(State)) Allocator.Error!void {
    const s = from.pop() orelse return;
    try to.append(b.gpa, .{ .text = try b.gpa.dupe(u8, b.text.items), .cursor = b.cursor, .anchor = b.anchor });
    b.text.clearRetainingCapacity();
    try b.text.appendSlice(b.gpa, s.text);
    b.gpa.free(s.text);
    b.cursor = @min(s.cursor, b.len());
    b.anchor = @min(s.anchor, b.len());
    b.last = .none;
    b.goal = null;
    b.version += 1;
    try b.reindex();
}

// ---------------------------------------------------------------------------
// Moving

/// The caret to `offset`; the selection grows to it when `select`.
pub fn moveTo(b: *Buffer, offset: u32, select: bool) void {
    b.cursor = @min(offset, b.len());
    if (!select) b.anchor = b.cursor;
    b.last = .none;
}

fn charLeft(b: *const Buffer, offset: u32) u32 {
    if (offset == 0) return 0;
    var at = offset - 1;
    while (at > 0 and isContinuation(b.text.items[at])) at -= 1;
    return at;
}

fn charRight(b: *const Buffer, offset: u32) u32 {
    if (offset >= b.len()) return b.len();
    var at = offset + 1;
    while (at < b.len() and isContinuation(b.text.items[at])) at += 1;
    return at;
}

fn wordLeft(b: *const Buffer, offset: u32) u32 {
    var at = offset;
    while (at > 0 and b.text.items[at - 1] == ' ') at -= 1;
    if (at > 0 and isWordChar(b.text.items[at - 1])) return b.wordStart(at);
    return b.charLeft(at);
}

fn wordRight(b: *const Buffer, offset: u32) u32 {
    var at = offset;
    if (at < b.len() and isWordChar(b.text.items[at])) return b.wordEnd(at);
    at = b.charRight(at);
    while (at < b.len() and b.text.items[at] == ' ') at += 1;
    return at;
}

pub fn moveLeft(b: *Buffer, select: bool, word: bool) void {
    b.goal = null;
    if (!select and !word) if (b.selection()) |s| return b.moveTo(s[0], false);
    b.moveTo(if (word) b.wordLeft(b.cursor) else b.charLeft(b.cursor), select);
}

pub fn moveRight(b: *Buffer, select: bool, word: bool) void {
    b.goal = null;
    if (!select and !word) if (b.selection()) |s| return b.moveTo(s[1], false);
    b.moveTo(if (word) b.wordRight(b.cursor) else b.charRight(b.cursor), select);
}

/// Up or down by `lines`, keeping to the column it started from.
pub fn vertical(b: *Buffer, lines: i64, select: bool) void {
    const line: i64 = b.lineOf(b.cursor);
    const goal = b.goal orelse b.column(b.cursor);
    const target = std.math.clamp(line + lines, 0, @as(i64, b.lineCount()) - 1);
    const to = if (line + lines < 0) 0 else if (line + lines >= b.lineCount()) b.len() else b.offsetAt(@intCast(target), goal);
    b.moveTo(to, select);
    b.goal = goal;
}

/// To the first character of the line after its indentation, or to the
/// very start when it is there already.
pub fn moveHome(b: *Buffer, select: bool) void {
    const line = b.lineOf(b.cursor);
    const first = b.lineStart(line) + b.indentOf(line);
    b.goal = null;
    b.moveTo(if (b.cursor == first) b.lineStart(line) else first, select);
}

pub fn moveEnd(b: *Buffer, select: bool) void {
    b.goal = null;
    b.moveTo(b.lineEnd(b.lineOf(b.cursor)), select);
}

pub fn selectAll(b: *Buffer) void {
    b.anchor = 0;
    b.cursor = b.len();
}

pub fn selectWordAt(b: *Buffer, offset: u32) void {
    const at = @min(offset, b.len());
    b.anchor = b.wordStart(at);
    b.cursor = b.wordEnd(at);
    if (b.anchor == b.cursor) b.cursor = b.charRight(at);
}

const testing = std.testing;

fn expectText(b: *const Buffer, want: []const u8) !void {
    try testing.expectEqualStrings(want, b.text.items);
}

test "typing, and undoing a word at a time" {
    var b: Buffer = try .init(testing.allocator, "");
    defer b.deinit();
    for ("hello") |c| try b.typeChar(c);
    try b.typeChar(' ');
    for ("world") |c| try b.typeChar(c);
    try expectText(&b, "hello world");
    try b.undo();
    try expectText(&b, "hello ");
    try b.undo();
    try expectText(&b, "hello");
    try b.redo();
    try expectText(&b, "hello ");
}

test "brackets close themselves, and a closer is stepped over" {
    var b: Buffer = try .init(testing.allocator, "");
    defer b.deinit();
    try b.typeChar('f');
    try b.typeChar('(');
    try expectText(&b, "f()");
    try testing.expectEqual(@as(u32, 2), b.cursor);
    try b.typeChar('x');
    try b.typeChar(')');
    try expectText(&b, "f(x)");
    try testing.expectEqual(@as(u32, 4), b.cursor);
    try b.typeChar('(');
    try b.backspace();
    try expectText(&b, "f(x)");
}

test "a new line keeps the indentation, and opens a block" {
    var b: Buffer = try .init(testing.allocator, "    fn f() {}");
    defer b.deinit();
    b.moveTo(12, false);
    try b.newline();
    try expectText(&b, "    fn f() {\n        \n    }");
    try testing.expectEqual(@as(u32, 21), b.cursor);
    try b.backspace();
    try expectText(&b, "    fn f() {\n    \n    }");
}

test "lines are shifted and commented as a block" {
    var b: Buffer = try .init(testing.allocator, "a\n    b\nc");
    defer b.deinit();
    b.selectAll();
    try b.shiftLines(false);
    try expectText(&b, "    a\n        b\n    c");
    try b.shiftLines(true);
    try expectText(&b, "a\n    b\nc");
    b.selectAll();
    try b.toggleComment();
    try expectText(&b, "// a\n//     b\n// c");
    try b.toggleComment();
    try expectText(&b, "a\n    b\nc");
}

test "up and down keep their column across a short line" {
    var b: Buffer = try .init(testing.allocator, "abcdef\nab\nabcdef");
    defer b.deinit();
    b.moveTo(5, false);
    b.vertical(1, false);
    try testing.expectEqual(@as(u32, 9), b.cursor);
    b.vertical(1, false);
    try testing.expectEqual(@as(u32, 15), b.cursor);
    try testing.expectEqual(@as(u32, 5), b.column(b.cursor));
}

test "columns count characters, not bytes" {
    var b: Buffer = try .init(testing.allocator, "\u{e9}t\u{e9}\tx");
    defer b.deinit();
    try expectText(&b, "\u{e9}t\u{e9}    x");
    try testing.expectEqual(@as(u32, 3), b.column(5));
    try testing.expectEqual(@as(u32, 5), b.offsetAt(0, 3));
    b.moveTo(5, false);
    b.moveLeft(false, false);
    try testing.expectEqual(@as(u32, 3), b.cursor);
}
