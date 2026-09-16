// SPDX-License-Identifier: BSD-2-Clause

//! The code editor's state and what the keyboard and the mouse do to it:
//! the buffer, where the view is scrolled to, and what the language service
//! said of the text - its colours, its mistakes, its outline - kept as of the
//! text's last change. Completions, signatures and hovers are asked for as
//! they are wanted, the way Godot's script editor asks GDScript.
//!
//! How it is drawn is `view.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flux = @import("fluxion_script");
const fuzzy = @import("fluxion_text").fuzzy;
const service = flux.service;
const Buffer = @import("Buffer.zig");

const Editor = @This();

pub const Metrics = struct {
    font_size: u16,
    /// How wide every character is: the font is monospaced.
    advance: f32,
    line_height: f32,
};

pub const Problem = struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,
    severity: flux.diag.Severity,
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

/// The first line and column in view.
top: u32 = 0,
left: u32 = 0,
/// How many lines and columns fit, from the view's size last frame.
rows: u32 = 30,
cols: u32 = 100,
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
drag: enum { none, text, scrollbar } = .none,
last_click: f64 = -1,
clicks: u8 = 0,
click_offset: u32 = 0,

pub fn init(gpa: Allocator, path: []const u8, text: []const u8, options: service.Options, metrics: Metrics) Allocator.Error!Editor {
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

pub fn deinit(ed: *Editor) void {
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
pub fn load(ed: *Editor, path: []const u8, text: []const u8) Allocator.Error!void {
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
pub fn refresh(ed: *Editor) void {
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
pub fn firstToken(ed: *const Editor, offset: u32) usize {
    var lo: usize = 0;
    var hi = ed.tokens.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (ed.tokens[mid].start + ed.tokens[mid].len <= offset) lo = mid + 1 else hi = mid;
    }
    return lo;
}

pub fn counts(ed: *const Editor) struct { errors: usize, warnings: usize } {
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
pub fn complete(ed: *Editor) void {
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
pub fn filter(ed: *Editor) void {
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

pub fn closeCompletion(ed: *Editor) void {
    ed.completion.open = false;
    ed.completion.shown.clearRetainingCapacity();
}

pub fn selectedItem(ed: *const Editor) ?service.Item {
    const c = &ed.completion;
    if (!c.open or c.selected >= c.shown.items.len) return null;
    return c.items[c.shown.items[c.selected]];
}

/// Puts the chosen completion in place of the word; a function gets its
/// parentheses, the caret between them when it takes arguments.
pub fn accept(ed: *Editor, index: usize) Allocator.Error!void {
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

pub fn askSignature(ed: *Editor) void {
    _ = ed.signature_arena.reset(.retain_capacity);
    ed.signature = service.signatureHelp(ed.gpa, ed.signature_arena.allocator(), ed.path, ed.buffer.text.items, ed.buffer.cursor, ed.options) catch null;
}

/// The pointer has rested on `offset`: after a moment, what is there is shown.
pub fn rest(ed: *Editor, offset: ?u32) void {
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

pub fn closePopups(ed: *Editor) void {
    ed.closeCompletion();
    ed.signature = null;
    ed.hover.shown = null;
    ed.hover.offset = null;
}

/// Where the name at the caret is declared: here, the caret goes there;
/// in another file, that file is asked to be opened.
pub fn goToDefinition(ed: *Editor, at: u32) void {
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

fn edited(ed: *Editor) void {
    ed.reveal = true;
    ed.typed_at = ed.now;
    ed.hover.shown = null;
}

/// A character typed. Typing a name opens completions, a `.` or an `@`
/// asks what comes after it, and `(` and `,` what the call takes.
pub fn typeChar(ed: *Editor, codepoint: u21) Allocator.Error!void {
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
pub fn key(ed: *Editor, k: Key, mods: Mods) Allocator.Error!bool {
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
pub fn offsetAt(ed: *const Editor, view_x: f32, view_y: f32, gutter: f32, x: f32, y: f32) u32 {
    const m = ed.metrics;
    const row: i64 = @intFromFloat(@floor((y - view_y) / m.line_height));
    const line: u32 = @intCast(std.math.clamp(@as(i64, ed.top) + row, 0, @as(i64, ed.buffer.lineCount()) - 1));
    const col: i64 = @intFromFloat(@round((x - view_x - gutter) / m.advance));
    return ed.buffer.offsetAt(line, @intCast(@max(0, @as(i64, ed.left) + col)));
}

/// The wheel, in notches: three lines each.
pub fn scroll(ed: *Editor, notches: f32, sideways: bool) void {
    const lines: i64 = @intFromFloat(@round(-notches * 3));
    if (sideways) {
        ed.left = @intCast(std.math.clamp(@as(i64, ed.left) + lines * 2, 0, 1000));
    } else {
        const most: i64 = @max(0, @as(i64, ed.buffer.lineCount()) - 1);
        ed.top = @intCast(std.math.clamp(@as(i64, ed.top) + lines, 0, most));
    }
    ed.hover.shown = null;
}

/// Brings the caret into view, when a change or a key moved it.
pub fn follow(ed: *Editor) void {
    if (!ed.reveal) return;
    ed.reveal = false;
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    const col = b.column(b.cursor);
    if (line < ed.top) ed.top = line;
    if (ed.rows > 2 and line + 2 > ed.top + ed.rows) ed.top = line + 2 - ed.rows;
    if (col < ed.left) ed.left = col -| 4;
    if (ed.cols > 8 and col + 2 > ed.left + ed.cols) ed.left = col + 8 - ed.cols;
}

test "completions narrow as the word is typed" {
    const gpa = std.testing.allocator;
    var ed: Editor = try .init(gpa, "t.flux", "fn fight(rounds: int) {\n    \n}\n", .{}, .{ .font_size = 16, .advance = 9, .line_height = 18 });
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
    var ed: Editor = try .init(gpa, "t.flux", text, .{}, .{ .font_size = 16, .advance = 9, .line_height = 18 });
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
    var ed: Editor = try .init(gpa, "t.flux", "fn heal(amount: int) {}\nfn f() {\n    \n}\n", .{}, .{ .font_size = 16, .advance = 9, .line_height = 18 });
    defer ed.deinit();
    ed.buffer.moveTo(@intCast(std.mem.indexOf(u8, ed.buffer.text.items, "    \n").? + 4), false);
    for ("hea") |c| try ed.typeChar(c);
    try std.testing.expectEqualStrings("heal", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try std.testing.expect(std.mem.indexOf(u8, ed.buffer.text.items, "    heal()\n") != null);
    try std.testing.expectEqual(@as(u8, ')'), ed.buffer.text.items[ed.buffer.cursor]);
    try std.testing.expectEqualStrings("heal(amount: int)", ed.signature.?.label);
}
