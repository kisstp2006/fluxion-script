// SPDX-License-Identifier: BSD-2-Clause

//! A `flux.edit.Code` drawn with fluxion-ui: one row a line, and only the
//! lines in view. A row is the line's text in runs, each coloured as the
//! language service says and each after the last as text is set, and the
//! line numbers go over the rows so that a line scrolled sideways passes
//! under them. Over it all float the selection, the lines under mistakes, the
//! caret, the scrollbar, and the completion list and the tooltips.
//!
//! Every place is measured through the code's `Metrics`, so the font can be
//! any: a `Ruler` measures with the interface's own measurer.

const std = @import("std");
const ui_lib = @import("fluxion_ui");
const flux = @import("fluxion_script");
const Theme = @import("Theme.zig");

const Code = flux.edit.Code;
const Ui = ui_lib.Ui;
const Color = ui_lib.Color;

const View = @This();

/// What the view's elements are called: to find the view with `boxOf`, and
/// to tell the view's popups from the rest of an interface.
ids: Ids = .{},
theme: *const Theme = &Theme.dark,
/// The interface's font for code - the rows, the line numbers, completions,
/// signatures, a hover's declaration - as an index into its measurer's
/// table: a monospaced one, when the interface has one. `Ruler.style` wants
/// the same, so that what is measured is what is drawn.
font: u16 = 0,
/// And for prose: the docs under completions, signatures and hovers.
prose_font: u16 = 0,

pub const Ids = struct {
    code: []const u8 = "code",
    completion: []const u8 = "code-completion",
    completion_doc: []const u8 = "code-completion-doc",
    signature: []const u8 = "code-signature",
    hover: []const u8 = "code-hover",
};

/// How the interface measures the code, for `Code.Metrics`: keep one where
/// it will not move, and point the code at it.
pub const Ruler = struct {
    ui: ?*Ui = null,
    style: ui_lib.TextStyle = .{},

    pub fn measure(self: *const Ruler) flux.edit.Measure {
        return .{ .context = self, .widthFn = widthOf };
    }

    fn widthOf(context: ?*const anyopaque, run: []const u8) f32 {
        const self: *const Ruler = @ptrCast(@alignCast(context.?));
        const ui = self.ui orelse return 0;
        const measurer = ui.measurer orelse return 0;
        return measurer.measure(run, self.style).width;
    }
};

/// One character's width, near enough for the widths of popups and the room
/// left round them.
fn em(ed: *const Code) f32 {
    return @max(1, ed.metrics.measure.width("0"));
}

pub fn gutterWidth(ed: *const Code) f32 {
    var digits: usize = 1;
    var n = ed.buffer.lineCount();
    while (n >= 10) : (n /= 10) digits += 1;
    var widest: [12]u8 = @splat('0');
    return ed.metrics.measure.width(widest[0..@max(digits, 3)]) + 2.5 * em(ed);
}

fn style(v: View, ed: *const Code, color: Color) ui_lib.TextStyle {
    return .{ .color = color, .font_size = ed.metrics.font_size, .wrap = .none, .line_height = @intFromFloat(ed.metrics.line_height), .font = v.font };
}

fn proseStyle(v: View, ed: *const Code, color: Color) ui_lib.TextStyle {
    var s = v.style(ed, color);
    s.font = v.prose_font;
    return s;
}

/// Where the view went, once the frame is laid out: what the next frame
/// scrolls by and the pointer is measured against. `scale` is how many of
/// the interface's pixels a pixel of the code's is.
pub fn measure(v: View, ed: *Code, ui: *Ui, scale: f32) void {
    const box = ui.boxOf(v.ids.code) orelse return;
    ed.view = .{ box.x / scale, box.y / scale, box.width / scale, box.height / scale };
    ed.rows = @max(1, @as(u32, @intFromFloat(@max(0, ed.view[3] / ed.metrics.line_height))));
    ed.gutter = gutterWidth(ed);
}

/// The code view. `focused` is whether it has the keyboard, which is when
/// the caret shows.
pub fn draw(v: View, ed: *Code, ui: *Ui, focused: bool) void {
    ed.follow();
    ui.open(.{
        .id = v.ids.code,
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = v.theme.code,
        .clip = .both,
        .cursor = .ibeam,
    });
    defer ui.close();
    ed.gutter = gutterWidth(ed);
    var line = ed.top;
    const last = @min(ed.buffer.lineCount(), ed.top + ed.rows + 1);
    while (line < last) : (line += 1) v.row(ed, ui, line);
    v.gutterColumn(ed, ui);
    v.selection(ed, ui);
    v.mistakes(ed, ui);
    if (focused and @mod(ed.now - ed.typed_at, 1.0) < 0.6) v.caret(ed, ui);
    scrollbar(ed, ui);
    v.completion(ed, ui);
    v.signature(ed, ui);
    v.hover(ed, ui);
}

fn row(v: View, ed: *Code, ui: *Ui, line: u32) void {
    const m = ed.metrics;
    const b = &ed.buffer;
    if (line == b.lineOf(b.cursor) and b.selection() == null) {
        rect(ui, 0, yOf(ed, line), @max(ed.view[2], 1), m.line_height, v.theme.current_line, 0);
    }

    // Tokens in their colours, what is between them plain.
    ui.open(.{
        .height = .fixed(m.line_height),
        .direction = .left_to_right,
        .floating = .{ .offset = .{ .x = ed.gutter - ed.left, .y = yOf(ed, line) }, .z_index = 1, .clip = true },
    });
    defer ui.close();
    const start = b.lineStart(line);
    const end = b.lineEnd(line);
    var at = start;
    var t = ed.firstToken(start);
    while (at < end) {
        var until = end;
        var color = v.theme.ink;
        if (t < ed.tokens.len) {
            const token = ed.tokens[t];
            if (token.start <= at) {
                until = @min(end, token.start + token.len);
                color = v.theme.token(token.type, token.modifiers);
            } else until = @min(end, token.start);
        }
        if (until > at) ui.text(b.text.items[at..until], v.style(ed, color));
        at = @max(until, at + 1);
        while (t < ed.tokens.len and ed.tokens[t].start + ed.tokens[t].len <= at) t += 1;
    }
}

/// The line numbers, red or yellow where something on the line is wrong.
fn gutterColumn(v: View, ed: *Code, ui: *Ui) void {
    const b = &ed.buffer;
    rect(ui, 0, 0, ed.gutter, @max(ed.view[3], 1), v.theme.gutter, 4);
    const current = b.lineOf(b.cursor);
    var line = ed.top;
    const last = @min(b.lineCount(), ed.top + ed.rows + 1);
    while (line < last) : (line += 1) {
        var color = if (line == current) v.theme.line_number_current else v.theme.line_number;
        for (ed.problems) |p| if (p.line == line) {
            color = if (p.severity == .@"error") v.theme.error_ink else v.theme.warning_ink;
            if (p.severity == .@"error") break;
        };
        var digits: [12]u8 = undefined;
        ui.open(.{
            .width = .fixed(ed.gutter - 1.5 * em(ed)),
            .height = .fixed(ed.metrics.line_height),
            .align_x = .right,
            .floating = .{ .offset = .{ .x = 0, .y = yOf(ed, line) }, .z_index = 5, .clip = true },
        });
        ui.text(std.fmt.bufPrint(&digits, "{d}", .{line + 1}) catch "?", v.style(ed, color));
        ui.close();
    }
}

/// A rectangle over the view, at a place in it.
fn rect(ui: *Ui, x: f32, y: f32, w: f32, h: f32, color: Color, z: i16) void {
    ui.empty(.{
        .width = .fixed(@max(w, 1)),
        .height = .fixed(h),
        .background_color = color,
        .floating = .{ .offset = .{ .x = x, .y = y }, .z_index = z, .clip = true },
    });
}

/// Where an offset of the text is in the view, sideways.
fn xOf(ed: *const Code, offset: u32) f32 {
    return ed.gutter + ed.xOf(offset) - ed.left;
}

fn yOf(ed: *const Code, line: u32) f32 {
    return (@as(f32, @floatFromInt(line)) - @as(f32, @floatFromInt(ed.top))) * ed.metrics.line_height;
}

fn inView(ed: *const Code, line: u32) bool {
    return line >= ed.top and line <= ed.top + ed.rows;
}

fn selection(v: View, ed: *Code, ui: *Ui) void {
    const b = &ed.buffer;
    const s = b.selection() orelse return;
    const first = b.lineOf(s[0]);
    const last = b.lineOf(s[1]);
    var line = @max(first, ed.top);
    while (line <= @min(last, ed.top + ed.rows)) : (line += 1) {
        const from = if (line == first) s[0] else b.lineStart(line);
        const to = if (line == last) s[1] else b.lineEnd(line);
        if (to < from) continue;
        // A selected line break shows as a sliver past the line's end.
        const tail: f32 = if (line == last) 0 else em(ed) / 2;
        const x = @max(ed.gutter, xOf(ed, from));
        rect(ui, x, yOf(ed, line), xOf(ed, to) + tail - x, ed.metrics.line_height, v.theme.selection, 2);
    }
}

fn mistakes(v: View, ed: *Code, ui: *Ui) void {
    const b = &ed.buffer;
    for (ed.problems) |p| {
        if (!inView(ed, p.line)) continue;
        const end = if (b.lineOf(p.end) == p.line) p.end else b.lineEnd(p.line);
        const x = @max(ed.gutter, xOf(ed, p.start));
        const width = @max(em(ed) / 2, xOf(ed, end) - x);
        const color = if (p.severity == .@"error") v.theme.error_ink else v.theme.warning_ink;
        rect(ui, x, yOf(ed, p.line) + ed.metrics.line_height - 2, width, 2, color, 3);
    }
}

fn caret(v: View, ed: *Code, ui: *Ui) void {
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    if (!inView(ed, line)) return;
    const x = xOf(ed, b.cursor);
    if (x < ed.gutter) return;
    rect(ui, x - 1, yOf(ed, line), 2, ed.metrics.line_height, v.theme.caret, 6);
}

fn scrollbar(ed: *Code, ui: *Ui) void {
    const total = ed.buffer.lineCount();
    if (total <= ed.rows) return;
    const h = ed.view[3];
    const thumb = @max(24, h * @as(f32, @floatFromInt(ed.rows)) / @as(f32, @floatFromInt(total)));
    const progress = @as(f32, @floatFromInt(ed.top)) / @as(f32, @floatFromInt(total - ed.rows));
    const color: Color = if (ed.drag == .scrollbar) .bytes(160, 160, 160, 160) else .bytes(128, 128, 128, 90);
    rect(ui, ed.view[2] - 10, @min(1, progress) * (h - thumb), 7, thumb, color, 7);
}

fn completion(v: View, ed: *Code, ui: *Ui) void {
    const c = &ed.completion;
    if (!c.open or c.shown.items.len == 0) return;
    const m = ed.metrics;
    var widest: usize = 12;
    for (c.shown.items) |i| widest = @max(widest, c.items[i].label.len);
    const width = std.math.clamp(@as(f32, @floatFromInt(widest + 28)) * em(ed), 280, 620);
    // Under the word being completed.
    const x = @max(ed.gutter, xOf(ed, c.start));
    const y = yOf(ed, ed.buffer.lineOf(ed.buffer.cursor)) + m.line_height + 2;
    ui.open(.{
        .id = v.ids.completion,
        .width = .fixed(width),
        .direction = .top_to_bottom,
        .padding = .all(3),
        .background_color = v.theme.popup,
        .border = .all(v.theme.border, 1),
        .corner_radius = .all(4),
        .capture = true,
        .preserve_focus = true,
        .floating = .{ .offset = .{ .x = x - 2 * em(ed), .y = y }, .z_index = 20 },
    });
    const last = @min(c.shown.items.len, c.first + Code.visible_items);
    var clicked: ?usize = null;
    for (c.shown.items[c.first..last], c.first..) |index, i| {
        const item = c.items[index];
        var name: [96]u8 = undefined;
        const row_id = std.fmt.bufPrint(&name, "{s}-{d}", .{ v.ids.completion, i }) catch v.ids.completion;
        if (ui.isElementReleased(row_id)) clicked = i;
        ui.open(.{
            .id = row_id,
            .width = .grow,
            .height = .fixed(m.line_height + 4),
            .direction = .left_to_right,
            .align_y = .center,
            .padding = .xy(6, 0),
            .gap = @intFromFloat(em(ed)),
            .corner_radius = .all(3),
            .background_color = if (i == c.selected) v.theme.popup_selected else if (ui.isPointerOver(row_id)) v.theme.hover else .transparent,
        });
        const letter, const color = v.theme.kind(item.kind);
        ui.text(letter, v.style(ed, color));
        ui.text(item.label, v.style(ed, v.theme.ink));
        ui.open(.{ .width = .grow, .height = .fixed(m.line_height), .clip = .x, .padding = .trbl(0, 0, 0, @intFromFloat(em(ed))) });
        if (item.detail.len > 0 and item.detail[0] != ' ') ui.text(item.detail, v.style(ed, v.theme.dim));
        ui.close();
        ui.close();
    }
    if (c.shown.items.len > Code.visible_items) {
        var count: [32]u8 = undefined;
        ui.open(.{ .width = .grow, .padding = .xy(6, 2), .align_x = .right });
        ui.text(std.fmt.bufPrint(&count, "{d} of {d}", .{ c.selected + 1, c.shown.items.len }) catch "", v.style(ed, v.theme.faint));
        ui.close();
    }
    ui.close();

    // What the chosen one is, beside the list.
    if (ed.selectedItem()) |item| if (item.doc != null or item.detail.len > 40) {
        ui.open(.{
            .id = v.ids.completion_doc,
            .width = .fixed(46 * em(ed)),
            .direction = .top_to_bottom,
            .gap = 6,
            .padding = .all(8),
            .background_color = v.theme.tooltip,
            .border = .all(v.theme.border, 1),
            .corner_radius = .all(4),
            .floating = .{ .attach = .id, .to = v.ids.completion, .anchor = .after, .offset = .{ .x = 4, .y = 0 }, .z_index = 21 },
        });
        wrapped(ui, item.detail, v.style(ed, v.theme.ink));
        if (item.doc) |doc| wrapped(ui, doc, v.proseStyle(ed, v.theme.dim));
        ui.close();
    };
    if (clicked) |i| {
        ed.completion.selected = i;
        ed.accept(i) catch {};
    }
}

/// Prose, broken into lines to fit its box.
fn wrapped(ui: *Ui, text: []const u8, text_style: ui_lib.TextStyle) void {
    var s = text_style;
    s.wrap = .words;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len == 0) continue;
        ui.open(.{ .width = .grow });
        ui.text(trimmed, s);
        ui.close();
    }
}

fn signature(v: View, ed: *Code, ui: *Ui) void {
    const sig = ed.signature orelse return;
    if (ed.completion.open) return;
    const m = ed.metrics;
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    if (!inView(ed, line)) return;
    // Above the line, its bottom edge on the line's top; under it when the
    // line is the first in view.
    const above = line > ed.top + 2;
    const y = if (above) yOf(ed, line) - 3 else yOf(ed, line) + m.line_height + 2;
    ui.open(.{
        .id = v.ids.signature,
        .direction = .top_to_bottom,
        .padding = .xy(8, 4),
        .gap = 4,
        .background_color = v.theme.tooltip,
        .border = .all(v.theme.border, 1),
        .corner_radius = .all(4),
        .floating = .{
            .offset = .{ .x = @max(ed.gutter, xOf(ed, b.cursor) - 4 * em(ed)), .y = y },
            .anchor = .{ .element_y = if (above) .bottom else .top },
            .z_index = 22,
        },
    });
    defer ui.close();
    ui.open(.{ .direction = .left_to_right });
    const active: ?[2]u32 = if (sig.active < sig.params.len) sig.params[sig.active] else null;
    const label = sig.label;
    if (active) |p| {
        ui.text(label[0..p[0]], v.style(ed, v.theme.ink));
        ui.text(label[p[0]..p[1]], v.style(ed, v.theme.accent));
        ui.text(label[p[1]..], v.style(ed, v.theme.ink));
    } else ui.text(label, v.style(ed, v.theme.ink));
    ui.close();
    if (sig.doc) |doc| {
        ui.open(.{ .width = .fixed(60 * em(ed)) });
        wrapped(ui, doc, v.proseStyle(ed, v.theme.dim));
        ui.close();
    }
}

fn hover(v: View, ed: *Code, ui: *Ui) void {
    const h = ed.hover.shown orelse return;
    if (ed.completion.open) return;
    const b = &ed.buffer;
    const line = b.lineOf(@min(h.span.start, b.len()));
    if (!inView(ed, line)) return;
    ui.open(.{
        .id = v.ids.hover,
        .direction = .top_to_bottom,
        .padding = .all(8),
        .gap = 6,
        .background_color = v.theme.tooltip,
        .border = .all(v.theme.border, 1),
        .corner_radius = .all(4),
        .floating = .{ .offset = .{ .x = @max(ed.gutter, xOf(ed, @intCast(h.span.start))), .y = yOf(ed, line) + ed.metrics.line_height + 2 }, .z_index = 23 },
    });
    defer ui.close();
    var lines = std.mem.splitScalar(u8, h.code, '\n');
    while (lines.next()) |code| {
        ui.open(.{ .direction = .left_to_right });
        ui.text(code, v.style(ed, v.theme.token(.function, .{})));
        ui.close();
    }
    if (h.doc) |doc| {
        ui.open(.{ .width = .fixed(60 * em(ed)), .direction = .top_to_bottom, .gap = 2 });
        wrapped(ui, doc, v.proseStyle(ed, v.theme.ink));
        ui.close();
    }
}

// ---------------------------------------------------------------------------
// The mouse

pub const Pointer = struct {
    x: f32,
    y: f32,
    down: bool,
    pressed: bool,
    mods: flux.edit.Mods,
};

/// What the mouse did to the text, from where everything was last frame:
/// a click puts the caret, a drag selects, a second click takes the word
/// and a third the line; ctrl and a click goes to the declaration; and
/// resting on a name shows what it is.
pub fn pointer(v: View, ed: *Code, ui: *Ui, p: Pointer) void {
    const x0, const y0, const w, const h = ed.view;
    const gutter = ed.gutter;
    const over_popup = ui.isPointerOver(v.ids.completion) or ui.isPointerOver(v.ids.completion_doc) or ui.isPointerOver(v.ids.signature) or ui.isPointerOver(v.ids.hover);
    const inside = p.x >= x0 and p.x < x0 + w and p.y >= y0 and p.y < y0 + h and !over_popup;
    if (!p.down) ed.drag = .none;
    switch (ed.drag) {
        .text => {
            ed.buffer.moveTo(ed.offsetAt(x0, y0, gutter, p.x, p.y), true);
            ed.reveal = true;
            return;
        },
        .scrollbar => {
            const total = ed.buffer.lineCount();
            const fraction = std.math.clamp((p.y - y0) / @max(1, h), 0, 1);
            ed.top = @min(@as(u32, @intFromFloat(fraction * @as(f32, @floatFromInt(total)))), total -| ed.rows);
            return;
        },
        .none => {},
    }
    if (!inside) {
        ed.rest(null);
        return;
    }
    if (p.pressed) {
        ed.closePopups();
        if (p.x >= x0 + w - 12 and ed.buffer.lineCount() > ed.rows) {
            ed.drag = .scrollbar;
            return;
        }
        const at = ed.offsetAt(x0, y0, gutter, p.x, p.y);
        if (p.mods.ctrl) return ed.goToDefinition(at);
        ed.clicks = if (ed.now - ed.last_click < 0.4 and at == ed.click_offset) ed.clicks % 3 + 1 else 1;
        ed.last_click = ed.now;
        ed.click_offset = at;
        switch (ed.clicks) {
            1 => {
                ed.buffer.moveTo(at, p.mods.shift);
                ed.drag = .text;
            },
            2 => ed.buffer.selectWordAt(at),
            else => {
                const line = ed.buffer.lineOf(at);
                ed.buffer.moveTo(ed.buffer.lineStart(line), false);
                ed.buffer.moveTo(@min(ed.buffer.len(), ed.buffer.lineEnd(line) + 1), true);
            },
        }
        ed.typed_at = ed.now;
        return;
    }
    if (p.x < x0 + gutter) return ed.rest(null);
    ed.rest(ed.offsetAt(x0, y0, gutter, p.x, p.y));
}

/// A frame of a view over `ed`, measured the way fluxion-ui's test measurer
/// measures: half the font size a character.
fn frame(view: View, ed: *Code, ui: *Ui, ruler: *Ruler) ![]const ui_lib.RenderCommand {
    ruler.* = .{ .ui = ui, .style = .{ .font_size = ed.metrics.font_size } };
    ed.metrics.measure = ruler.measure();
    ui.begin(.init(800, 600));
    ui.open(.{ .width = .grow, .height = .grow });
    view.draw(ed, ui, true);
    ui.close();
    const drawn = try ui.end();
    view.measure(ed, ui, 1);
    return drawn;
}

test "a line's indentation is drawn as part of its text, and the caret where the text says" {
    const gpa = std.testing.allocator;
    var ed: Code = try .init(gpa, "t.flux", "fn f() {\n    if (true) {\n        print(1);\n    }\n}\n", .{}, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{ .ids = .{ .code = "script-code" } };
    ed.buffer.moveTo(@intCast(std.mem.indexOf(u8, ed.buffer.text.items, "print").?), false);
    const drawn = try frame(view, &ed, &ui, &ruler);

    // The fourth line, "    }", has no token in it: one run, spaces and all.
    const gutter = gutterWidth(&ed);
    const found = for (drawn) |c| {
        if (c.config == .text and c.bounding_box.y == 3 * 16 and c.bounding_box.x >= gutter) break c;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("    }", found.config.text.text);
    try std.testing.expectEqual(gutter, found.bounding_box.x);

    // The caret before `print`, eight characters of eight pixels in, on the
    // third line; and the view found by the name it was given.
    try std.testing.expectEqual(gutter + 8 * 8, xOf(&ed, ed.buffer.cursor));
    try std.testing.expectEqual(@as(f32, 800), ed.view[2]);
}

test "code is drawn in the code's font, and a doc in the prose font" {
    const gpa = std.testing.allocator;
    var ed: Code = try .init(gpa, "t.flux", "fn f() {}\n", .{}, .{ .font_size = 16, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    ed.hover.shown = .{ .span = .{ .start = 3, .end = 4 }, .code = "fn f()", .doc = "Does nothing." };
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    var ruler: Ruler = .{};
    const view: View = .{ .font = 3, .prose_font = 1 };
    const drawn = try frame(view, &ed, &ui, &ruler);

    var code_runs: usize = 0;
    var docs: usize = 0;
    for (drawn) |c| if (c.config == .text) {
        const t = c.config.text;
        if (std.mem.eql(u8, t.text, "Does nothing.")) {
            try std.testing.expectEqual(@as(u16, 1), t.font);
            docs += 1;
        } else {
            // The row's runs, the line number, and the hover's declaration.
            try std.testing.expectEqual(@as(u16, 3), t.font);
            code_runs += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 1), docs);
    try std.testing.expect(code_runs >= 3);
}
