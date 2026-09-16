// SPDX-License-Identifier: BSD-2-Clause

//! The code editor, drawn with fluxion-ui: one row a line, and only the
//! lines in view. A row is its number and then the line's text in runs,
//! each coloured as the language service says: the font is monospaced, so a
//! column is a width and every run lands where its column says. Over the
//! rows float the selection, the lines under mistakes, the caret, the
//! scrollbar, and the completion list and the tooltips.

const std = @import("std");
const ui_lib = @import("fluxion_ui");
const service = @import("fluxion_script").service;
const Editor = @import("Editor.zig");
const theme = @import("theme.zig");

const Ui = ui_lib.Ui;
const Color = ui_lib.Color;

pub fn gutterWidth(ed: *const Editor) f32 {
    var digits: f32 = 1;
    var n = ed.buffer.lineCount();
    while (n >= 10) : (n /= 10) digits += 1;
    return (@max(digits, 3) + 2.5) * ed.metrics.advance;
}

fn style(ed: *const Editor, color: Color) ui_lib.TextStyle {
    return .{ .color = color, .font_size = ed.metrics.font_size, .wrap = .none, .line_height = @intFromFloat(ed.metrics.line_height) };
}

/// Where the view went, once the frame is laid out: what the next frame
/// scrolls by and the mouse is measured against.
pub fn measure(ed: *Editor, ui: *Ui) void {
    const m = ed.metrics;
    const box = ui.boxOf("code") orelse return;
    ed.view = .{ box.x, box.y, box.width, box.height };
    ed.rows = @max(1, @as(u32, @intFromFloat(@max(0, box.height / m.line_height))));
    ed.cols = @max(1, @as(u32, @intFromFloat(@max(0, (box.width - gutterWidth(ed)) / m.advance))) -| 1);
}

/// The code view. `focused` is whether the window has the keyboard, which
/// is when the caret shows.
pub fn draw(ed: *Editor, ui: *Ui, focused: bool) void {
    ed.follow();
    ui.open(.{
        .id = "code",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = theme.code,
        .clip = .both,
        .cursor = .ibeam,
    });
    defer ui.close();
    const gutter = gutterWidth(ed);
    var line = ed.top;
    const last = @min(ed.buffer.lineCount(), ed.top + ed.rows + 1);
    while (line < last) : (line += 1) row(ed, ui, line, gutter);
    selection(ed, ui, gutter);
    mistakes(ed, ui, gutter);
    if (focused and @mod(ed.now - ed.typed_at, 1.0) < 0.6) caret(ed, ui, gutter);
    scrollbar(ed, ui);
    completion(ed, ui, gutter);
    signature(ed, ui, gutter);
    hover(ed, ui, gutter);
}

fn row(ed: *Editor, ui: *Ui, line: u32, gutter: f32) void {
    const m = ed.metrics;
    const b = &ed.buffer;
    const current = line == b.lineOf(b.cursor);
    ui.open(.{
        .width = .grow,
        .height = .fixed(m.line_height),
        .direction = .left_to_right,
        .background_color = if (current and b.selection() == null) theme.current_line else .transparent,
    });
    defer ui.close();

    // Its number, red or yellow when something on it is wrong.
    var number_color = if (current) theme.line_number_current else theme.line_number;
    for (ed.problems) |p| if (p.line == line) {
        number_color = if (p.severity == .@"error") theme.error_ink else theme.warning_ink;
        if (p.severity == .@"error") break;
    };
    ui.open(.{ .width = .fixed(gutter), .height = .fixed(m.line_height), .align_x = .right, .padding = .trbl(0, @intFromFloat(m.advance * 1.5), 0, 0), .background_color = theme.gutter });
    var digits: [12]u8 = undefined;
    ui.text(std.fmt.bufPrint(&digits, "{d}", .{line + 1}) catch "?", style(ed, number_color));
    ui.close();

    // The line's text: tokens in their colours, what is between them plain.
    const start = b.lineStart(line);
    const end = b.lineEnd(line);
    var at = start;
    var t = ed.firstToken(start);
    var col: u32 = 0;
    while (at < end and col < ed.left + ed.cols) {
        var until = end;
        var color = theme.ink;
        if (t < ed.tokens.len) {
            const token = ed.tokens[t];
            if (token.start <= at) {
                until = @min(end, token.start + token.len);
                color = theme.token(token.type, token.modifiers);
            } else until = @min(end, token.start);
        }
        piece(ed, ui, b.text.items[at..until], color, &col, ed.left);
        at = until;
        while (t < ed.tokens.len and ed.tokens[t].start + ed.tokens[t].len <= at) t += 1;
    }
}

/// Part of a line in one colour, less the first `left` columns, scrolled
/// off to the left.
fn piece(ed: *Editor, ui: *Ui, text: []const u8, color: Color, col: *u32, left: u32) void {
    var from: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (col.* += 1) {
        i = @min(text.len, i + (std.unicode.utf8ByteSequenceLength(text[i]) catch 1));
        if (col.* < left) from = i;
    }
    if (from < text.len) ui.text(text[from..], style(ed, color));
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

fn xOf(ed: *const Editor, gutter: f32, col: u32) f32 {
    return gutter + (@as(f32, @floatFromInt(col)) - @as(f32, @floatFromInt(ed.left))) * ed.metrics.advance;
}

fn yOf(ed: *const Editor, line: u32) f32 {
    return (@as(f32, @floatFromInt(line)) - @as(f32, @floatFromInt(ed.top))) * ed.metrics.line_height;
}

fn inView(ed: *const Editor, line: u32) bool {
    return line >= ed.top and line <= ed.top + ed.rows;
}

fn selection(ed: *Editor, ui: *Ui, gutter: f32) void {
    const b = &ed.buffer;
    const s = b.selection() orelse return;
    const first = b.lineOf(s[0]);
    const last = b.lineOf(s[1]);
    var line = @max(first, ed.top);
    while (line <= @min(last, ed.top + ed.rows)) : (line += 1) {
        const from = if (line == first) b.column(s[0]) else 0;
        // A selected line break shows as a sliver past the line's end.
        const to = if (line == last) b.column(s[1]) else b.column(b.lineEnd(line)) + 1;
        if (to <= from) continue;
        const x = @max(gutter, xOf(ed, gutter, from));
        rect(ui, x, yOf(ed, line), xOf(ed, gutter, to) - x, ed.metrics.line_height, theme.selection, 1);
    }
}

fn mistakes(ed: *Editor, ui: *Ui, gutter: f32) void {
    const b = &ed.buffer;
    for (ed.problems) |p| {
        if (!inView(ed, p.line)) continue;
        const end_col = if (b.lineOf(p.end) == p.line) b.column(p.end) else b.column(b.lineEnd(p.line));
        const cols = @max(end_col, p.column + 1) - p.column;
        const x = @max(gutter, xOf(ed, gutter, p.column));
        const color = if (p.severity == .@"error") theme.error_ink else theme.warning_ink;
        rect(ui, x, yOf(ed, p.line) + ed.metrics.line_height - 2, @as(f32, @floatFromInt(cols)) * ed.metrics.advance, 2, color, 2);
    }
}

fn caret(ed: *Editor, ui: *Ui, gutter: f32) void {
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    if (!inView(ed, line)) return;
    const x = xOf(ed, gutter, b.column(b.cursor));
    if (x < gutter) return;
    rect(ui, x - 1, yOf(ed, line), 2, ed.metrics.line_height, theme.caret, 3);
}

fn scrollbar(ed: *Editor, ui: *Ui) void {
    const total = ed.buffer.lineCount();
    if (total <= ed.rows) return;
    const h = ed.view[3];
    const thumb = @max(24, h * @as(f32, @floatFromInt(ed.rows)) / @as(f32, @floatFromInt(total)));
    const progress = @as(f32, @floatFromInt(ed.top)) / @as(f32, @floatFromInt(total - ed.rows));
    const color: Color = if (ed.drag == .scrollbar) .bytes(160, 160, 160, 160) else .bytes(128, 128, 128, 90);
    rect(ui, ed.view[2] - 10, @min(1, progress) * (h - thumb), 7, thumb, color, 4);
}

/// Where a popup goes: under the caret's line.
fn underCaret(ed: *const Editor, gutter: f32) [2]f32 {
    const b = &ed.buffer;
    const line = b.lineOf(b.cursor);
    return .{ @max(gutter, xOf(ed, gutter, b.column(ed.completion.start))), yOf(ed, line) + ed.metrics.line_height + 2 };
}

fn completion(ed: *Editor, ui: *Ui, gutter: f32) void {
    const c = &ed.completion;
    if (!c.open or c.shown.items.len == 0) return;
    const m = ed.metrics;
    var widest: usize = 12;
    for (c.shown.items) |i| widest = @max(widest, c.items[i].label.len);
    const width = std.math.clamp(@as(f32, @floatFromInt(widest + 28)) * m.advance, 280, 620);
    const at = underCaret(ed, gutter);
    ui.open(.{
        .id = "completion",
        .width = .fixed(width),
        .direction = .top_to_bottom,
        .padding = .all(3),
        .background_color = theme.popup,
        .border = .all(theme.border, 1),
        .corner_radius = .all(4),
        .capture = true,
        .preserve_focus = true,
        .floating = .{ .offset = .{ .x = at[0] - 2 * m.advance, .y = at[1] }, .z_index = 20 },
    });
    const last = @min(c.shown.items.len, c.first + Editor.visible_items);
    var clicked: ?usize = null;
    for (c.shown.items[c.first..last], c.first..) |index, i| {
        const item = c.items[index];
        var name: [24]u8 = undefined;
        const id = std.fmt.bufPrint(&name, "completion-{d}", .{i}) catch "completion-item";
        if (ui.isElementReleased(id)) clicked = i;
        ui.open(.{
            .id = id,
            .width = .grow,
            .height = .fixed(m.line_height + 4),
            .direction = .left_to_right,
            .align_y = .center,
            .padding = .xy(6, 0),
            .gap = @intFromFloat(m.advance),
            .corner_radius = .all(3),
            .background_color = if (i == c.selected) theme.popup_selected else if (ui.isPointerOver(id)) theme.button_hover else .transparent,
        });
        const letter, const color = theme.kind(item.kind);
        ui.text(letter, style(ed, color));
        ui.text(item.label, style(ed, theme.ink));
        ui.open(.{ .width = .grow, .height = .fixed(m.line_height), .clip = .x, .padding = .trbl(0, 0, 0, @intFromFloat(m.advance)) });
        if (item.detail.len > 0 and item.detail[0] != ' ') ui.text(item.detail, style(ed, theme.dim));
        ui.close();
        ui.close();
    }
    if (c.shown.items.len > Editor.visible_items) {
        var count: [32]u8 = undefined;
        ui.open(.{ .width = .grow, .padding = .xy(6, 2), .align_x = .right });
        ui.text(std.fmt.bufPrint(&count, "{d} of {d}", .{ c.selected + 1, c.shown.items.len }) catch "", style(ed, theme.faint));
        ui.close();
    }
    ui.close();

    // What the chosen one is, beside the list.
    if (ed.selectedItem()) |item| if (item.doc != null or item.detail.len > 40) {
        ui.open(.{
            .id = "completion-doc",
            .width = .fixed(46 * m.advance),
            .direction = .top_to_bottom,
            .gap = 6,
            .padding = .all(8),
            .background_color = theme.tooltip,
            .border = .all(theme.border, 1),
            .corner_radius = .all(4),
            .floating = .{ .attach = .id, .to = "completion", .anchor = .after, .offset = .{ .x = 4, .y = 0 }, .z_index = 21 },
        });
        wrapped(ed, ui, item.detail, theme.ink);
        if (item.doc) |doc| wrapped(ed, ui, doc, theme.dim);
        ui.close();
    };
    if (clicked) |i| {
        ed.completion.selected = i;
        ed.accept(i) catch {};
    }
}

/// Prose, broken into lines to fit its box.
fn wrapped(ed: *Editor, ui: *Ui, text: []const u8, color: Color) void {
    var s = style(ed, color);
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

fn signature(ed: *Editor, ui: *Ui, gutter: f32) void {
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
        .id = "signature",
        .direction = .top_to_bottom,
        .padding = .xy(8, 4),
        .gap = 4,
        .background_color = theme.tooltip,
        .border = .all(theme.border, 1),
        .corner_radius = .all(4),
        .floating = .{
            .offset = .{ .x = @max(gutter, xOf(ed, gutter, b.column(b.cursor)) - 4 * m.advance), .y = y },
            .anchor = .{ .element_y = if (above) .bottom else .top },
            .z_index = 22,
        },
    });
    defer ui.close();
    ui.open(.{ .direction = .left_to_right });
    const active: ?[2]u32 = if (sig.active < sig.params.len) sig.params[sig.active] else null;
    const label = sig.label;
    if (active) |p| {
        ui.text(label[0..p[0]], style(ed, theme.ink));
        ui.text(label[p[0]..p[1]], style(ed, theme.accent));
        ui.text(label[p[1]..], style(ed, theme.ink));
    } else ui.text(label, style(ed, theme.ink));
    ui.close();
    if (sig.doc) |doc| {
        ui.open(.{ .width = .fixed(60 * m.advance) });
        wrapped(ed, ui, doc, theme.dim);
        ui.close();
    }
}

fn hover(ed: *Editor, ui: *Ui, gutter: f32) void {
    const h = ed.hover.shown orelse return;
    if (ed.completion.open) return;
    const m = ed.metrics;
    const b = &ed.buffer;
    const line = b.lineOf(@min(h.span.start, b.len()));
    if (!inView(ed, line)) return;
    ui.open(.{
        .id = "hover",
        .direction = .top_to_bottom,
        .padding = .all(8),
        .gap = 6,
        .background_color = theme.tooltip,
        .border = .all(theme.border, 1),
        .corner_radius = .all(4),
        .floating = .{ .offset = .{ .x = @max(gutter, xOf(ed, gutter, b.column(h.span.start))), .y = yOf(ed, line) + m.line_height + 2 }, .z_index = 23 },
    });
    defer ui.close();
    var lines = std.mem.splitScalar(u8, h.code, '\n');
    while (lines.next()) |code| {
        ui.open(.{ .direction = .left_to_right });
        ui.text(code, style(ed, theme.token(.function, .{})));
        ui.close();
    }
    if (h.doc) |doc| {
        ui.open(.{ .width = .fixed(60 * m.advance), .direction = .top_to_bottom, .gap = 2 });
        wrapped(ed, ui, doc, theme.ink);
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
    mods: Editor.Mods,
};

/// What the mouse did to the text, from where everything was last frame:
/// a click puts the caret, a drag selects, a second click takes the word
/// and a third the line; ctrl and a click goes to the declaration; and
/// resting on a name shows what it is.
pub fn pointer(ed: *Editor, ui: *Ui, p: Pointer) void {
    const x0, const y0, const w, const h = ed.view;
    const gutter = gutterWidth(ed);
    const over_popup = ui.isPointerOver("completion") or ui.isPointerOver("completion-doc") or ui.isPointerOver("signature") or ui.isPointerOver("hover");
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

test "a line's indentation is drawn as part of its text" {
    const gpa = std.testing.allocator;
    var ed: Editor = try .init(gpa, "t.flux", "fn f() {\n    if (true) {\n        print(1);\n    }\n}\n", .{}, .{ .font_size = 16, .advance = 8, .line_height = 16 });
    defer ed.deinit();
    ed.refresh();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    ui.begin(.init(800, 600));
    ui.open(.{ .width = .grow, .height = .grow });
    draw(&ed, &ui, false);
    ui.close();
    const drawn = try ui.end();

    // The fourth line, "    }", has no token in it: one run, spaces and all.
    const gutter = gutterWidth(&ed);
    for (drawn) |c| if (c.config == .text and c.bounding_box.y == 3 * 16 and c.bounding_box.x >= gutter) {
        try std.testing.expectEqualStrings("    }", c.config.text.text);
        try std.testing.expectEqual(gutter, c.bounding_box.x);
        return;
    };
    return error.TestExpectedEqual;
}
