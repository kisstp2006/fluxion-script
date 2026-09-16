// SPDX-License-Identifier: BSD-2-Clause

//! The code editor's state and what the keyboard and the mouse do to it:
//! the buffer, where the view is scrolled to, and what the language service
//! said of the text - its colours, its mistakes, its outline - kept as of the
//! text's last change. Completions, signatures and hovers are asked for as
//! they are wanted, the way Godot's script editor asks GDScript.
//!
//! Nothing here draws. Widths come from the interface through `Metrics`,
//! measured, so any font will do; `fluxion_script_ui` is the view on
//! fluxion-ui.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fuzzy = @import("fluxion_text").fuzzy;
const service = @import("../service.zig");
const Buffer = @import("Buffer.zig");

const Code = @This();

pub const Metrics = struct {
    font_size: u16,
    line_height: f32,
    /// How wide a piece of the code is on screen, which only the interface
    /// knows: its font is the system's, and its characters are not all of
    /// one width. Zero-width until the panel hands one over.
    measure: Measure = .{},
};

/// How the code is measured, from the interface that draws it.
pub const Measure = struct {
    context: ?*const anyopaque = null,
    widthFn: ?*const fn (context: ?*const anyopaque, run: []const u8) f32 = null,

    pub fn width(self: Measure, run: []const u8) f32 {
        const f = self.widthFn orelse return 0;
        return f(self.context, run);
    }
};

pub const Problem = struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,
    severity: @import("../diag.zig").Severity,
    message: []const u8,
};

pub const Key = enum { left, right, up, down, home, end, page_up, page_down, backspace, delete, enter, tab, escape, space, f12, a, y, z, slash };

pub const Mods = struct { shift: bool = false, ctrl: bool = false };

pub const Completion = struct {
    open: bool = false,
    items: []const service.Item = &.{},
    /// Indexes into `items`: those matching what is typed, best first.
    shown: std.ArrayList(u32) = .empty,
    selected: usize = 0,
    /// The first of `shown` in the list's window.
    first: usize = 0,
    /// Where the word being completed starts.
    start: u32 = 0,
    arena: std.heap.ArenaAllocator,
};

pub const Hover = struct {
    /// Where the pointer has rested, and since when.
    offset: ?u32 = null,
    since: f64 = 0,
    shown: ?service.Hover = null,
    arena: std.heap.ArenaAllocator,
};

gpa: Allocator,
buffer: Buffer,
/// Where it is saved, or `untitled.flux`.
path: []u8,
options: service.Options,
metrics: Metrics,

analysis: ?*service.Analysis = null,
/// The buffer's version the analysis is of.
analyzed: u64 = 0,
/// What the view draws from the analysis, remade with it.
info: std.heap.ArenaAllocator,
tokens: []const service.Token = &.{},
problems: []const Problem = &.{},
symbols: []const service.Symbol = &.{},

/// The first line in view, and how far the view is scrolled sideways, in
/// pixels: a character is not a column when the font is the system's.
top: u32 = 0,
left: f32 = 0,
/// How many lines fit, from the view's size last frame.
rows: u32 = 30,
/// Keep the caret in view at the next frame.
reveal: bool = true,

completion: Completion,
signature: ?service.Signature = null,
signature_arena: std.heap.ArenaAllocator,
hover: Hover,

/// Set by go to definition when the declaration is in another file.
open_request: ?[]u8 = null,
/// The time, from the frame loop; the caret blinks against it.
now: f64 = 0,
typed_at: f64 = 0,

/// Where the view was drawn last frame: x, y, width, height.
view: [4]f32 = .{ 0, 0, 0, 0 },
/// How wide the line numbers were, from the view.
gutter: f32 = 0,
drag: enum { none, text, scrollbar } = .none,
last_click: f64 = -1,
clicks: u8 = 0,
click_offset: u32 = 0,

pub fn init(gpa: Allocator, path: []const u8, text: []const u8, options: service.Options, metrics: Metrics) Allocator.Error!Code {
    return .{
        .gpa = gpa,
        .buffer = try .init(gpa, text),
        .path = try gpa.dupe(u8, path),
        .options = options,
        .metrics = metrics,
        .info = .init(gpa),
        .completion = .{ .arena = .init(gpa) },
        .signature_arena = .init(gpa),
        .hover = .{ .arena = .init(gpa) },
    };
}

pub fn deinit(ed: *Code) void {
    if (ed.analysis) |a| a.deinit();
    ed.info.deinit();
    ed.completion.shown.deinit(ed.gpa);
    ed.completion.arena.deinit();
    ed.signature_arena.deinit();
    ed.hover.arena.deinit();
    ed.buffer.deinit();
    ed.gpa.free(ed.path);
    if (ed.open_request) |p| ed.gpa.free(p);
}

/// Another file in the editor, as it is on disk.
pub fn load(ed: *Code, path: []const u8, text: []const u8) Allocator.Error!void {
    try ed.buffer.setText(text);
    ed.gpa.free(ed.path);
    ed.path = try ed.gpa.dupe(u8, path);
    ed.top = 0;
    ed.left = 0;
    ed.closePopups();
}

// ---------------------------------------------------------------------------
// What the service says

/// Compiles the text again if it changed since it was last compiled: once a
/// frame at most, and never while the keys come faster than that.
pub fn refresh(ed: *Code) void {
    if (ed.analyzed == ed.buffer.version) return;
    ed.analyzed = ed.buffer.version;
    if (ed.analysis) |a| a.deinit();
    ed.analysis = null;
    _ = ed.info.reset(.retain_capacity);
    ed.tokens = &.{};
    ed.problems = &.{};
    ed.symbols = &.{};
    const a = service.Analysis.init(ed.gpa, ed.path, ed.buffer.text.items, ed.options) catch return;
    ed.analysis = a;
    const arena = ed.info.allocator();
    ed.tokens = service.highlight.tokens(a, arena) catch &.{};
    ed.symbols = a.symbols(arena) catch &.{};
    var list: std.ArrayList(Problem) = .empty;
    for (a.diagnostics.items.items) |*d| {
        if (!a.isHere(d)) continue;
        const at = d.primary() orelse continue;
        const start = @min(at.span.start, ed.buffer.len());
        const message = if (d.help) |h| std.fmt.allocPrint(arena, "{s} - {s}", .{ d.message, h }) catch d.message else d.message;
        list.append(arena, .{
            .start = start,
            .end = @min(@max(at.span.end, start), ed.buffer.len()),
            .line = ed.buffer.lineOf(start),
            .column = ed.buffer.column(start),
            .severity = d.severity,
            .message = message,
        }) catch break;
    }
    ed.problems = list.items;
}

/// The first token that ends after `offset`.
pub fn firstToken(ed: *const Code, offset: u32) usize {
    var lo: usize = 0;
    var hi = ed.tokens.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (ed.tokens[mid].start + ed.tokens[mid].len <= offset) lo = mid + 1 else hi = mid;
    }
    return lo;
}

pub fn counts(ed: *const Code) struct { errors: usize, warnings: usize } {
    var e: usize = 0;
    var w: usize = 0;
    for (ed.problems) |p| switch (p.severity) {
        .@"error" => e += 1,
        .warning => w += 1,
        .note => {},
    };
    return .{ .errors = e, .warnings = w };
}

// ---------------------------------------------------------------------------
// Completion

/// Asks what could be typed at the caret, and opens the list if anything could.
pub fn complete(ed: *Code) void {
    ed.refresh();
    _ = ed.completion.arena.reset(.retain_capacity);
    const found = service.complete(ed.gpa, ed.completion.arena.allocator(), ed.path, ed.buffer.text.items, ed.buffer.cursor, ed.options) catch return ed.closeCompletion();
    ed.completion.items = found.items;
    ed.completion.start = found.start;
    ed.completion.open = found.items.len > 0;
    ed.filter();
}

/// The items that match the word typed so far, best first: the service's
/// order - locals before the rest - then how well they match.
pub fn filter(ed: *Code) void {
    const c = &ed.completion;
    if (!c.open) return;
    if (ed.buffer.cursor < c.start or ed.buffer.selection() != null) return ed.closeCompletion();
    const typed = ed.buffer.text.items[c.start..ed.buffer.cursor];
    for (typed) |ch| if (!Buffer.isWordChar(ch)) return ed.closeCompletion();
    c.shown.clearRetainingCapacity();
    for (c.items, 0..) |item, i| {
        if (fuzzy.score(typed, item.label, .{}) == null) continue;
        c.shown.append(ed.gpa, @intCast(i)) catch return;
    }
    const Order = struct {
        items: []const service.Item,
        typed: []const u8,
        fn less(o: @This(), x: u32, y: u32) bool {
            const a = o.items[x];
            const b = o.items[y];
            // A name typed out exactly comes first, then the service's rank.
            const ea = std.mem.eql(u8, a.label, o.typed);
            const eb = std.mem.eql(u8, b.label, o.typed);
            if (ea != eb) return ea;
            if (a.rank != b.rank) return a.rank < b.rank;
            const sa = fuzzy.score(o.typed, a.label, .{}) orelse 0;
            const sb = fuzzy.score(o.typed, b.label, .{}) orelse 0;
            if (sa != sb) return sa > sb;
            return std.mem.order(u8, a.label, b.label) == .lt;
        }
    };
    std.mem.sort(u32, c.shown.items, Order{ .items = c.items, .typed = typed }, Order.less);
    if (c.shown.items.len == 0 or (c.shown.items.len == 1 and std.mem.eql(u8, c.items[c.shown.items[0]].label, typed))) {
        return ed.closeCompletion();
    }
    c.selected = 0;
    c.first = 0;
}

pub fn closeCompletion(ed: *Code) void {
    ed.completion.open = false;
    ed.completion.shown.clearRetainingCapacity();
}

pub fn selectedItem(ed: *const Code) ?service.Item {
    const c = &ed.completion;
    if (!c.open or c.selected >= c.shown.items.len) return null;
    return c.items[c.shown.items[c.selected]];
}

/// Puts the chosen completion in place of the word; a function gets its
/// parentheses, the caret between them when it takes arguments.
pub fn accept(ed: *Code, index: usize) Allocator.Error!void {
    const c = &ed.completion;
    if (index >= c.shown.items.len) return;
    const item = c.items[c.shown.items[index]];
    const b = &ed.buffer;
    const end = b.wordEnd(b.cursor);
    const callable = switch (item.kind) {
        .function, .method, .builtin_function, .builtin_method => true,
        else => false,
    };
    const next: u8 = if (end < b.len()) b.text.items[end] else 0;
    if (callable and next != '(') {
        const no_args = std.mem.indexOf(u8, item.detail, "()") != null;
        const text = try std.fmt.allocPrint(ed.gpa, "{s}()", .{item.label});
        defer ed.gpa.free(text);
        try b.replace(c.start, end, text, .other);
        if (!no_args) b.moveTo(b.cursor - 1, false);
        ed.closeCompletion();
        if (!no_args) ed.askSignature();
        return;
    }
    try b.replace(c.start, end, item.label, .other);
    ed.closeCompletion();
}

// ---------------------------------------------------------------------------
// Signatures and hovers

pub fn askSignature(ed: *Code) void {
    _ = ed.signature_arena.reset(.retain_capacity);
    ed.signature = service.signatureHelp(ed.gpa, ed.signature_arena.allocator(), ed.path, ed.buffer.text.items, ed.buffer.cursor, ed.options) catch null;
}

/// The pointer has rested on `offset`: after a moment, what is there is shown.
pub fn rest(ed: *Code, offset: ?u32) void {
    const h = &ed.hover;
    if (offset == null) {
        h.offset = null;
        h.shown = null;
        return;
    }
    if (h.shown) |s| if (offset.? >= s.span.start and offset.? <= s.span.end) return;
    if (h.offset == null or h.offset.? != offset.?) {
        h.offset = offset;
        h.since = ed.now;
        h.shown = null;
        return;
    }
    if (h.shown != null or ed.now - h.since < 0.45) return;
    const a = ed.analysis orelse return;
    if (ed.analyzed != ed.buffer.version) return;
    _ = h.arena.reset(.retain_capacity);
    const arena = h.arena.allocator();
    const found = (a.hover(arena, offset.?) catch return) orelse return;
    // The analysis goes at the next change; what is shown stays.
    h.shown = .{
        .span = found.span,
        .code = arena.dupe(u8, found.code) catch return,
        .doc = if (found.doc) |d| arena.dupe(u8, d) catch null else null,
    };
}

pub fn closePopups(ed: *Code) void {
    ed.closeCompletion();
    ed.signature = null;
    ed.hover.shown = null;
    ed.hover.offset = null;
}

/// Where the name at the caret is declared: here, the caret goes there;
/// in another file, that file is asked to be opened.
pub fn goToDefinition(ed: *Code, at: u32) void {
    ed.refresh();
    const a = ed.analysis orelse return;
    const decl = a.definition(at) orelse return;
    if (decl.file == a.file) {
        ed.buffer.moveTo(decl.span.start, false);
        ed.buffer.moveTo(decl.span.end, true);
        ed.reveal = true;
        return;
    }
    if (ed.open_request) |p| ed.gpa.free(p);
    ed.open_request = ed.gpa.dupe(u8, a.fileName(decl.file)) catch null;
}

// ---------------------------------------------------------------------------
// The keyboard

fn edited(ed: *Code) void {
    ed.reveal = true;
    ed.typed_at = ed.now;
    ed.hover.shown = null;
}

/// A character typed. Typing a name opens completions, a `.` or an `@`
/// asks what comes after it, and `(` and `,` what the call takes.
pub fn typeChar(ed: *Code, codepoint: u21) Allocator.Error!void {
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(codepoint, &utf8) catch return;
    if (n == 1) try ed.buffer.typeChar(utf8[0]) else try ed.buffer.insert(utf8[0..n]);
    ed.edited();
    const c: u8 = if (n == 1) utf8[0] else 0;
    if (Buffer.isWordChar(c)) {
        if (ed.completion.open) {
            ed.filter();
        } else if (!std.ascii.isDigit(c) and ed.buffer.cursor - ed.buffer.wordStart(ed.buffer.cursor) == 1) {
            ed.complete();
        }
    } else if (c == '.' or c == '@') {
        ed.complete();
    } else {
        ed.closeCompletion();
    }
    if (c == '(' or c == ',') ed.askSignature();
    if (c == ')') ed.signature = null;
}

/// A key pressed. Returns whether it did anything.
pub fn key(ed: *Code, k: Key, mods: Mods) Allocator.Error!bool {
    const b = &ed.buffer;
    const c = &ed.completion;
    if (c.open) switch (k) {
        .up, .down, .page_up, .page_down => {
            const count = c.shown.items.len;
            const step: i64 = switch (k) {
                .up => -1,
                .down => 1,
                .page_up => -8,
                else => 8,
            };
            const next = @as(i64, @intCast(c.selected)) + step;
            c.selected = @intCast(@mod(next, @as(i64, @intCast(count))));
            if (c.selected < c.first) c.first = c.selected;
            if (c.selected >= c.first + visible_items) c.first = c.selected + 1 - visible_items;
            return true;
        },
        .enter, .tab => {
            try ed.accept(c.selected);
            ed.edited();
            return true;
        },
        .escape => {
            ed.closeCompletion();
            return true;
        },
        else => {},
    };
    switch (k) {
        .left => b.moveLeft(mods.shift, mods.ctrl),
        .right => b.moveRight(mods.shift, mods.ctrl),
        .up => b.vertical(-1, mods.shift),
        .down => b.vertical(1, mods.shift),
        .page_up => {
            b.vertical(-@as(i64, ed.rows), mods.shift);
            ed.top -|= ed.rows;
        },
        .page_down => {
            b.vertical(ed.rows, mods.shift);
            ed.top = @min(ed.top + ed.rows, b.lineCount() -| 1);
        },
        .home => if (mods.ctrl) b.moveTo(0, mods.shift) else b.moveHome(mods.shift),
        .end => if (mods.ctrl) b.moveTo(b.len(), mods.shift) else b.moveEnd(mods.shift),
        .backspace => {
            if (mods.ctrl) try b.deleteWord(false) else try b.backspace();
            ed.edited();
            ed.filter();
            if (ed.signature != null) ed.askSignature();
            return true;
        },
        .delete => {
            if (mods.ctrl) try b.deleteWord(true) else try b.delete();
            ed.edited();
            return true;
        },
        .enter => {
            try b.newline();
            ed.edited();
            ed.signature = null;
            return true;
        },
        .tab => {
            if (mods.shift) try b.shiftLines(true) else try b.tab();
            ed.edited();
            return true;
        },
        .escape => {
            ed.closePopups();
            return true;
        },
        .space => if (mods.ctrl) {
            ed.complete();
            return true;
        } else return false,
        .f12 => {
            ed.goToDefinition(b.cursor);
            return true;
        },
        .a => if (mods.ctrl) b.selectAll() else return false,
        .z => if (mods.ctrl) {
            if (mods.shift) try b.redo() else try b.undo();
            ed.edited();
            return true;
        } else return false,
        .y => if (mods.ctrl) {
            try b.redo();
            ed.edited();
            return true;
        } else return false,
        .slash => if (mods.ctrl) {
            try b.toggleComment();
            ed.edited();
            return true;
        } else return false,
    }
    // The caret moved: the lists that were about where it was go.
    ed.reveal = true;
    ed.closeCompletion();
    if (ed.signature != null) ed.askSignature();
    return true;
}

pub const visible_items = 10;

// ---------------------------------------------------------------------------
// The mouse

/// The offset under a point of the window, with the view where it was drawn
/// last and `gutter` its width.
pub fn offsetAt(ed: *const Code, view_x: f32, view_y: f32, gutter: f32, x: f32, y: f32) u32 {
    const m = ed.metrics;
    const row: i64 = @intFromFloat(@floor((y - view_y) / m.line_height));
    const line: u32 = @intCast(std.math.clamp(@as(i64, ed.top) + row, 0, @as(i64, ed.buffer.lineCount()) - 1));
    return ed.offsetInLine(line, x - view_x - gutter + ed.left);
}

/// The offset in `line` nearest `wanted` pixels from the line's start: each
/// character is measured until the pointer is past the middle of one.
pub fn offsetInLine(ed: *const Code, line: u32, wanted: f32) u32 {
    const b = &ed.buffer;
    const start = b.lineStart(line);
    const text = b.lineText(line);
    if (wanted <= 0) return start;
    var at: usize = 0;
    var before: f32 = 0;
    while (at < text.len) {
        const step = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
        const next = @min(text.len, at + step);
        const after = ed.metrics.measure.width(text[0..next]);
        if (wanted < (before + after) / 2) break;
        before = after;
        at = next;
    }
    return start + @as(u32, @intCast(at));
}

/// How far into the line `offset` is, in pixels.
pub fn xOf(ed: *const Code, offset: u32) f32 {
    const b = &ed.buffer;
    const line = b.lineOf(offset);
    const start = b.lineStart(line);
    const text = b.lineText(line);
    const upto = @min(text.len, offset - start);
    return ed.metrics.measure.width(text[0..upto]);
}

/// The wheel, in notches: three lines each.
pub fn scroll(ed: *Code, notches: f32, sideways: bool) void {
    const lines: i64 = @intFromFloat(@round(-notches * 3));
    if (sideways) {
        ed.left = std.math.clamp(ed.left + @as(f32, @floatFromInt(lines)) * ed.metrics.line_height, 0, 8000);
    } else {
        const most: i64 = @max(0, @as(i64, ed.buffer.lineCount()) - 1);
        ed.top = @intCast(std.math.clamp(@as(i64, ed.top) + lines, 0, most));
    }
    ed.hover.shown = null;
}

/// Brings the caret into view, when a change or a key moved it.
pub fn follow(ed: *Code) void {
    if (!ed.reveal) return;
    // Not before the view has been measured once: there is no width yet to
    // keep the caret inside, and a guess scrolls the first frame sideways.
    if (ed.view[2] <= 0) return;
    ed.reveal = false;
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    if (line < ed.top) ed.top = line;
    if (ed.rows > 2 and line + 2 > ed.top + ed.rows) ed.top = line + 2 - ed.rows;

    // Sideways, in pixels, with a character's room either side of the caret.
    const room = ed.metrics.line_height;
    const x = ed.xOf(ed.buffer.cursor);
    const width = @max(64, ed.view[2] - ed.gutter);
    if (x < ed.left + room) ed.left = @max(0, x - room);
    if (x > ed.left + width - room) ed.left = x - width + room;
}

test "completions narrow as the word is typed" {
    const gpa = std.testing.allocator;
    var ed: Code = try .init(gpa, "t.flux", "fn fight(rounds: int) {\n    \n}\n", .{}, .{ .font_size = 16, .line_height = 18 });
    defer ed.deinit();
    ed.buffer.moveTo(28, false);
    for ("rou") |c| try ed.typeChar(c);
    try std.testing.expect(ed.completion.open);
    try std.testing.expectEqualStrings("rounds", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try std.testing.expectEqualStrings("fn fight(rounds: int) {\n    rounds\n}\n", ed.buffer.text.items);
    try ed.typeChar('.');
    try std.testing.expect(!ed.completion.open);
    ed.refresh();
    try std.testing.expect(ed.problems.len > 0);
}

test "go to definition selects the name where it is declared" {
    const gpa = std.testing.allocator;
    const text = "struct Ball {\n    var x: int = 0;\n}\nfn f() {\n    var b = Ball{};\n    print(b.x);\n}\n";
    var ed: Code = try .init(gpa, "t.flux", text, .{}, .{ .font_size = 16, .line_height = 18 });
    defer ed.deinit();
    ed.goToDefinition(@intCast(std.mem.indexOf(u8, text, "Ball{}").? + 2));
    try std.testing.expectEqualStrings("Ball", ed.buffer.selectedText());
    try std.testing.expectEqual(@as(u32, 0), ed.buffer.lineOf(ed.buffer.cursor));
    ed.goToDefinition(@intCast(std.mem.indexOf(u8, text, "b.x").? + 2));
    try std.testing.expectEqualStrings("x", ed.buffer.selectedText());
    try std.testing.expectEqual(@as(u32, 1), ed.buffer.lineOf(ed.buffer.cursor));
}

test "a function is completed with its parentheses, and its signature shown" {
    const gpa = std.testing.allocator;
    var ed: Code = try .init(gpa, "t.flux", "fn heal(amount: int) {}\nfn f() {\n    \n}\n", .{}, .{ .font_size = 16, .line_height = 18 });
    defer ed.deinit();
    ed.buffer.moveTo(@intCast(std.mem.indexOf(u8, ed.buffer.text.items, "    \n").? + 4), false);
    for ("hea") |c| try ed.typeChar(c);
    try std.testing.expectEqualStrings("heal", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try std.testing.expect(std.mem.indexOf(u8, ed.buffer.text.items, "    heal()\n") != null);
    try std.testing.expectEqual(@as(u8, ')'), ed.buffer.text.items[ed.buffer.cursor]);
    try std.testing.expectEqualStrings("heal(amount: int)", ed.signature.?.label);
}

/// A font whose `i` is narrow and whose other letters are not: what a
/// proportional one does to columns.
fn narrowI(_: ?*const anyopaque, run: []const u8) f32 {
    var w: f32 = 0;
    for (run) |c| w += if (c == 'i') 4 else 10;
    return w;
}

test "places in a line are measured, not counted, in any font" {
    const gpa = std.testing.allocator;
    var ed: Code = try .init(gpa, "t.flux", "iiii wide and wider\nx\n", .{}, .{ .font_size = 16, .line_height = 20, .measure = .{ .widthFn = narrowI } });
    defer ed.deinit();

    // Four narrow letters and a space are 26 pixels, not five columns' 50.
    try std.testing.expectEqual(@as(f32, 26), ed.xOf(5));
    try std.testing.expectEqual(@as(u32, 5), ed.offsetInLine(0, 26));
    // A point goes to the nearer side of the character under it.
    try std.testing.expectEqual(@as(u32, 1), ed.offsetInLine(0, 3));
    try std.testing.expectEqual(@as(u32, 0), ed.offsetInLine(0, 1));
    // Past the end is the end; before the start is the start.
    try std.testing.expectEqual(@as(u32, 19), ed.offsetInLine(0, 999));
    try std.testing.expectEqual(@as(u32, 20), ed.offsetInLine(1, -5));
    // Through the view: gutter 30, the view at (100, 50), the second line.
    try std.testing.expectEqual(@as(u32, 21), ed.offsetAt(100, 50, 30, 100 + 30 + 9, 50 + 25));

    // Scrolled sideways, the caret at the end of a long line is kept in view.
    ed.view = .{ 0, 0, 130, 100 };
    ed.gutter = 30;
    ed.buffer.moveTo(19, false);
    ed.reveal = true;
    ed.follow();
    try std.testing.expect(ed.left > 0);
    try std.testing.expect(ed.xOf(19) - ed.left <= 100);
}
