// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Writer = std.Io.Writer;
const json = @import("fluxion_json");

const diag = @import("../diag.zig");
const Sources = @import("Sources.zig");

pub const Options = struct {
    color: bool = false,
    /// Lines of the file shown around nothing: a label shows its own line.
    tab_width: u8 = 4,
};

const Style = enum {
    reset,
    bold,
    err,
    warning,
    note,
    gutter,
    secondary,

    fn code(style: Style) []const u8 {
        return switch (style) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .err => "\x1b[1;31m",
            .warning => "\x1b[1;33m",
            .note => "\x1b[1;36m",
            .gutter => "\x1b[1;34m",
            .secondary => "\x1b[1;34m",
        };
    }
};

const Painter = struct {
    w: *Writer,
    color: bool,

    fn set(p: Painter, style: Style) Writer.Error!void {
        if (p.color) try p.w.writeAll(style.code());
    }
};

fn severityStyle(severity: diag.Severity) Style {
    return switch (severity) {
        .@"error" => .err,
        .warning => .warning,
        .note => .note,
    };
}

pub fn diagnostic(w: *Writer, sources: *Sources, d: *const diag.Diagnostic, options: Options) Writer.Error!void {
    const p: Painter = .{ .w = w, .color = options.color };
    try p.set(severityStyle(d.severity));
    try w.writeAll(d.severity.word());
    try p.set(.reset);
    try p.set(.bold);
    try w.print(": {s}", .{d.message});
    try p.set(.reset);
    try w.writeByte('\n');

    var width: usize = 1;
    for (d.labels.items) |l| {
        const pos = sources.position(l.at.file, l.at.span.start);
        width = @max(width, digits(pos.line));
    }

    var previous_file: ?diag.FileId = null;
    var first = true;
    var shown: [16]bool = @splat(false);
    const labels = d.labels.items[0..@min(d.labels.items.len, shown.len)];
    var order: [2]bool = .{ true, false };
    for (&order) |want_primary| {
        for (labels, 0..) |l, index| {
            if (l.primary != want_primary or shown[index]) continue;
            if (sources.get(l.at.file) == null) continue;
            const pos = sources.position(l.at.file, l.at.span.start);
            if (previous_file == null or previous_file.? != l.at.file) {
                try spaces(w, width);
                try p.set(.gutter);
                try w.writeAll(if (first) "--> " else "::: ");
                try p.set(.reset);
                try w.print("{s}:{d}:{d}\n", .{ sources.name(l.at.file), pos.line, pos.column });
                try gutter(p, width, null);
                try w.writeByte('\n');
            }
            first = false;
            previous_file = l.at.file;
            var same_line: [16]diag.Label = undefined;
            var count: usize = 0;
            for (labels, 0..) |other, j| {
                if (shown[j] or other.at.file != l.at.file) continue;
                if (sources.position(other.at.file, other.at.span.start).line != pos.line) continue;
                same_line[count] = other;
                count += 1;
                shown[j] = true;
            }
            std.mem.sort(diag.Label, same_line[0..count], {}, byStart);
            try lineBlock(p, sources, same_line[0..count], pos.line, width, severityStyle(d.severity), options);
        }
    }

    for (d.notes.items) |n| {
        try tail(p, width, "note", n);
    }
    if (d.help) |h| try tail(p, width, "help", h);
}

fn tail(p: Painter, width: usize, word: []const u8, message: []const u8) Writer.Error!void {
    try spaces(p.w, width + 1);
    try p.set(.gutter);
    try p.w.writeAll("= ");
    try p.set(.bold);
    try p.w.writeAll(word);
    try p.set(.reset);
    try p.w.print(": {s}\n", .{message});
}

fn byStart(_: void, a: diag.Label, b: diag.Label) bool {
    return a.at.span.start < b.at.span.start;
}

const Marker = struct { start: usize, len: usize, label: diag.Label };

/// One source line, and under it a mark for every label on it: `^` for
/// where the trouble is, `-` for what explains it. The rightmost label's
/// words follow its mark; the others' go on lines of their own below.
/// The part of a long line worth showing: around the labels, as much as
/// fits in `max_shown` bytes. A minified file's one line of forty thousand
/// is not printed whole under its error.
fn window(line: []const u8, line_start: u32, labels: []const diag.Label) struct { from: usize, to: usize } {
    const max_shown = 120;
    if (line.len <= max_shown) return .{ .from = 0, .to = line.len };
    var lo: usize = line.len;
    var hi: usize = 0;
    for (labels) |l| {
        lo = @min(lo, @min(l.at.span.start -| line_start, line.len));
        hi = @max(hi, @min(l.at.span.end -| line_start, line.len));
    }
    var from = lo -| 40;
    var to = @min(line.len, @max(hi + 40, from + max_shown));
    if (to - from > max_shown) to = from + max_shown;
    while (from > 0 and line[from] & 0xC0 == 0x80) from -= 1;
    while (to < line.len and line[to] & 0xC0 == 0x80) to += 1;
    return .{ .from = from, .to = to };
}

fn lineBlock(
    p: Painter,
    sources: *Sources,
    labels: []const diag.Label,
    line_no: u32,
    width: usize,
    primary_style: Style,
    options: Options,
) Writer.Error!void {
    const w = p.w;
    const first = labels[0];
    const line = sources.line(first.at.file, line_no);
    const file = sources.get(first.at.file).?;
    const line_start = first.at.span.start - byteColumn(file.text, first.at.span.start);
    const shown = window(line, line_start, labels);
    const cut = "...";
    const lead: usize = if (shown.from > 0) cut.len else 0;
    var markers: [16]Marker = undefined;
    for (labels, markers[0..labels.len]) |l, *m| m.* = .{ .start = lead, .len = 0, .label = l };

    try gutter(p, width, line_no);
    try w.writeByte(' ');
    if (lead > 0) try w.writeAll(cut);
    var display_col: usize = lead;
    var i: usize = shown.from;
    while (i < shown.to) {
        const offset = line_start + i;
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const cell: usize = if (line[i] == '\t') options.tab_width else 1;
        for (markers[0..labels.len]) |*m| {
            if (offset == m.label.at.span.start) m.start = display_col;
            if (offset >= m.label.at.span.start and offset < @min(m.label.at.span.end, line_start + line.len)) m.len += cell;
        }
        if (line[i] == '\t') try w.splatByteAll(' ', cell) else try w.writeAll(line[i..@min(line.len, i + len)]);
        display_col += cell;
        i += len;
    }
    if (shown.to < line.len) try w.writeAll(cut);
    for (markers[0..labels.len]) |*m| {
        if (m.label.at.span.start >= line_start + shown.to) m.start = display_col;
        m.len = @max(m.len, 1);
    }
    try w.writeByte('\n');

    try gutter(p, width, null);
    try w.writeByte(' ');
    var col: usize = 0;
    for (markers[0..labels.len]) |m| {
        if (m.start < col) continue;
        try spaces(w, m.start - col);
        try p.set(if (m.label.primary) primary_style else .secondary);
        try w.splatByteAll(if (m.label.primary) '^' else '-', m.len);
        try p.set(.reset);
        col = m.start + m.len;
    }
    const last = markers[labels.len - 1];
    if (last.label.message.len > 0) {
        try p.set(if (last.label.primary) primary_style else .secondary);
        try w.print(" {s}", .{last.label.message});
        try p.set(.reset);
    }
    try w.writeByte('\n');

    var n = labels.len - 1;
    while (n > 0) {
        n -= 1;
        const m = markers[n];
        if (m.label.message.len == 0) continue;
        try gutter(p, width, null);
        try w.writeByte(' ');
        col = 0;
        for (markers[0..n]) |left| {
            if (left.label.message.len == 0 or left.start < col) continue;
            try spaces(w, left.start - col);
            try p.set(.secondary);
            try w.writeByte('|');
            try p.set(.reset);
            col = left.start + 1;
        }
        try spaces(w, m.start -| col);
        try p.set(if (m.label.primary) primary_style else .secondary);
        try w.writeAll(m.label.message);
        try p.set(.reset);
        try w.writeByte('\n');
    }
}

fn byteColumn(source: []const u8, offset: u32) u32 {
    const at = @min(offset, source.len);
    const nl = std.mem.lastIndexOfScalar(u8, source[0..at], '\n') orelse return @intCast(at);
    return @intCast(at - nl - 1);
}

fn gutter(p: Painter, width: usize, line: ?u32) Writer.Error!void {
    try p.set(.gutter);
    if (line) |n| {
        try spaces(p.w, width - digits(n));
        try p.w.print("{d} |", .{n});
    } else {
        try spaces(p.w, width + 1);
        try p.w.writeByte('|');
    }
    try p.set(.reset);
}

fn spaces(w: *Writer, n: usize) Writer.Error!void {
    try w.splatByteAll(' ', n);
}

fn digits(n: u32) usize {
    var count: usize = 1;
    var rest = n / 10;
    while (rest > 0) : (rest /= 10) count += 1;
    return count;
}

pub fn all(w: *Writer, sources: *Sources, list: *const diag.Diagnostics, options: Options) Writer.Error!void {
    for (list.items.items, 0..) |*d, i| {
        if (i > 0) try w.writeByte('\n');
        try diagnostic(w, sources, d, options);
    }
}

const JsonLabel = struct {
    file: []const u8,
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
    message: []const u8,
    primary: bool,
};

const JsonDiagnostic = struct {
    severity: []const u8,
    message: []const u8,
    file: []const u8,
    line: u32,
    column: u32,
    labels: []const JsonLabel,
    notes: []const []const u8,
    help: ?[]const u8,
};

/// One JSON object per line, for an editor or a language server to read.
pub fn jsonLines(w: *Writer, sources: *Sources, list: *const diag.Diagnostics) Writer.Error!void {
    var buffer: [16]JsonLabel = undefined;
    for (list.items.items) |*d| {
        var count: usize = 0;
        var main: JsonLabel = .{ .file = "", .line = 0, .column = 0, .end_line = 0, .end_column = 0, .message = "", .primary = true };
        for (d.labels.items) |l| {
            const start = sources.position(l.at.file, l.at.span.start);
            const end = sources.position(l.at.file, l.at.span.end);
            const entry: JsonLabel = .{
                .file = sources.name(l.at.file),
                .line = start.line,
                .column = start.column,
                .end_line = end.line,
                .end_column = end.column,
                .message = l.message,
                .primary = l.primary,
            };
            if (l.primary and main.line == 0) main = entry;
            if (count < buffer.len) {
                buffer[count] = entry;
                count += 1;
            }
        }
        const out: JsonDiagnostic = .{
            .severity = d.severity.word(),
            .message = d.message,
            .file = main.file,
            .line = main.line,
            .column = main.column,
            .labels = buffer[0..count],
            .notes = d.notes.items,
            .help = d.help,
        };
        json.write(w, out, .{}) catch return error.WriteFailed;
        try w.writeByte('\n');
    }
}

const testing = std.testing;

test "an error points at its span with the line under the header" {
    var sources: Sources = .init(testing.allocator);
    defer sources.deinit();
    const file = try sources.add("player.flux", "struct Player {\n    var hp: int = 100;\n}\nfn f(p: Player) {\n    p.hp = \"full\";\n}\n");
    var list: diag.Diagnostics = .init(testing.allocator);
    defer list.deinit();
    const start: u32 = @intCast(std.mem.indexOf(u8, sources.get(file).?.text, "\"full\"").?);
    const decl: u32 = @intCast(std.mem.indexOf(u8, sources.get(file).?.text, "var hp").?);
    _ = try (try (try (try list.err(.{ .file = file, .span = .{ .start = start, .end = start + 6 } }, "cannot assign a string to `hp`, which is an int", .{}))
        .text("this is a string", .{}))
        .label(.{ .file = file, .span = .{ .start = decl, .end = decl + 17 } }, "`hp` is declared here", .{}))
        .help("convert it with `int(...)`", .{});

    var buffer: [1024]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try all(&w, &sources, &list, .{});
    try testing.expectEqualStrings(
        \\error: cannot assign a string to `hp`, which is an int
        \\ --> player.flux:5:12
        \\  |
        \\5 |     p.hp = "full";
        \\  |            ^^^^^^ this is a string
        \\2 |     var hp: int = 100;
        \\  |     ----------------- `hp` is declared here
        \\  = help: convert it with `int(...)`
        \\
    , w.buffered());
}

test "a long line is cut to the part around the mistake" {
    var sources: Sources = .init(testing.allocator);
    defer sources.deinit();
    const text = "const s = \"" ++ "x" ** 300 ++ "\"; const n: int = s;\n";
    const file = try sources.add("long.flux", text);
    var list: diag.Diagnostics = .init(testing.allocator);
    defer list.deinit();
    const at: u32 = @intCast(std.mem.lastIndexOfScalar(u8, text, 's').?);
    _ = try (try list.err(.{ .file = file, .span = .{ .start = at, .end = at + 1 } }, "the variable must be int, not string", .{})).text("this is string", .{});
    var buffer: [1024]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try all(&w, &sources, &list, .{});
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "1 | ...xxxxx") != null);
    try testing.expect(std.mem.indexOf(u8, out, "x" ** 200) == null);
    const shown = std.mem.indexOf(u8, out, "= s;").? + 2;
    const caret = std.mem.indexOf(u8, out, "^ this is string").?;
    const line_start = std.mem.lastIndexOfScalar(u8, out[0..shown], '\n').? + 1;
    const caret_line = std.mem.lastIndexOfScalar(u8, out[0..caret], '\n').? + 1;
    try testing.expectEqual(shown - line_start, caret - caret_line);
}

test "tabs are shown as spaces and the caret follows them" {
    var sources: Sources = .init(testing.allocator);
    defer sources.deinit();
    const file = try sources.add("t.flux", "\tx = y;\n");
    var list: diag.Diagnostics = .init(testing.allocator);
    defer list.deinit();
    _ = try list.err(.{ .file = file, .span = .{ .start = 5, .end = 6 } }, "`y` is not declared", .{});
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try all(&w, &sources, &list, .{});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "1 |     x = y;\n  |         ^\n") != null);
}

test "json lines carry the place and the labels" {
    var sources: Sources = .init(testing.allocator);
    defer sources.deinit();
    const file = try sources.add("t.flux", "var x = ;\n");
    var list: diag.Diagnostics = .init(testing.allocator);
    defer list.deinit();
    _ = try list.err(.{ .file = file, .span = .{ .start = 8, .end = 9 } }, "expected an expression", .{});
    var buffer: [512]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try jsonLines(&w, &sources, &list);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "{\"severity\":\"error\",\"message\":\"expected an expression\",\"file\":\"t.flux\",\"line\":1,\"column\":9,"));
}
