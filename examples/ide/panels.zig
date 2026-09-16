// SPDX-License-Identifier: BSD-2-Clause

//! Everything around the code: the toolbar with Run and Save, the script's
//! members down the left - its outline, from the language service - the
//! problems and the output under it, and a status line. Each returns what
//! was clicked, for the frame loop to do.

const std = @import("std");
const ui_lib = @import("fluxion_ui");
const flux = @import("fluxion_script");
const service = flux.service;
const Editor = @import("Editor.zig");
const Runner = @import("Runner.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const Ui = ui_lib.Ui;
const Color = ui_lib.Color;

pub const Action = union(enum) {
    none,
    run,
    stop,
    save,
    open,
    /// Put the caret here, and look at it.
    jump: u32,
};

pub const Tab = enum { problems, output };

pub const State = struct {
    tab: Tab = .problems,
    /// The panel's height, dragged at its top edge.
    panel_height: f32 = 200,
    dragging: bool = false,
};

fn style(ed: *const Editor, color: Color) ui_lib.TextStyle {
    return .{ .color = color, .font_size = ed.metrics.font_size, .wrap = .none, .line_height = @intFromFloat(ed.metrics.line_height) };
}

/// A button with a label: true on the frame the mouse is let go on it.
fn button(ui: *Ui, ed: *const Editor, id: []const u8, label: []const u8, color: Color) bool {
    const lit = ui.isPointerOver(id);
    const down = ui.isElementPressed(id);
    ui.open(.{
        .id = id,
        .padding = .xy(12, 5),
        .corner_radius = .all(4),
        .cursor = .pointing_hand,
        .background_color = if (down) theme.button_down else if (lit) theme.button_hover else theme.button,
    });
    defer ui.close();
    ui.text(label, style(ed, color));
    return ui.justReleased();
}

/// The whole window. `focused` is whether it has the keyboard.
pub fn shell(ui: *Ui, ed: *Editor, runner: *Runner, state: *State, focused: bool) Action {
    var action: Action = .none;
    ui.open(.{ .width = .grow, .height = .grow, .direction = .top_to_bottom, .background_color = theme.window });
    defer ui.close();

    // The toolbar.
    {
        ui.open(.{ .width = .grow, .direction = .left_to_right, .align_y = .center, .padding = .xy(10, 6), .gap = 8, .background_color = theme.toolbar });
        defer ui.close();
        ui.text("Flux", style(ed, theme.accent));
        var name: [300]u8 = undefined;
        const title = std.fmt.bufPrint(&name, "{s}{s}", .{ std.fs.path.basename(ed.path), if (ed.buffer.modified()) " *" else "" }) catch ed.path;
        ui.text(title, style(ed, theme.ink));
        ui.empty(.{ .width = .grow });
        if (runner.running) ui.text("running - save to reload", style(ed, theme.run));
        if (runner.vm != null and runner.running) {
            if (button(ui, ed, "stop", "Stop", theme.stop)) action = .stop;
        } else if (button(ui, ed, "run", "Run  F5", theme.run)) action = .run;
        if (button(ui, ed, "save", "Save  Ctrl+S", theme.ink)) action = .save;
        if (button(ui, ed, "open", "Open  Ctrl+O", theme.ink)) action = .open;
    }

    // The members, and the code.
    {
        ui.open(.{ .width = .grow, .height = .grow, .direction = .left_to_right });
        defer ui.close();
        if (members(ui, ed)) |at| action = .{ .jump = at };
        ui.empty(.{ .width = .fixed(1), .height = .grow, .background_color = theme.border });
        view.draw(ed, ui, focused);
    }

    // The edge the panel is resized by.
    {
        const hot = ui.isPointerOver("splitter") or state.dragging;
        ui.empty(.{ .id = "splitter", .width = .grow, .height = .fixed(4), .cursor = .resize_ns, .background_color = if (hot) theme.accent else theme.border });
    }

    // Problems and output.
    {
        ui.open(.{ .width = .grow, .height = .fixed(state.panel_height), .direction = .top_to_bottom, .background_color = theme.panel });
        defer ui.close();
        const count = ed.counts();
        {
            ui.open(.{ .width = .grow, .direction = .left_to_right, .padding = .xy(8, 4), .gap = 6, .align_y = .center });
            defer ui.close();
            var label: [48]u8 = undefined;
            const problems_label = std.fmt.bufPrint(&label, "Problems ({d})", .{count.errors + count.warnings}) catch "Problems";
            if (tab(ui, ed, "tab-problems", problems_label, state.tab == .problems)) state.tab = .problems;
            if (tab(ui, ed, "tab-output", "Output", state.tab == .output)) state.tab = .output;
            ui.empty(.{ .width = .grow });
            if (state.tab == .output and button(ui, ed, "clear", "Clear", theme.dim)) runner.clear();
        }
        ui.empty(.{ .width = .grow, .height = .fixed(1), .background_color = theme.border });
        switch (state.tab) {
            .problems => if (problems(ui, ed)) |at| {
                action = .{ .jump = at };
            },
            .output => output(ui, ed, runner),
        }
    }

    // The status line.
    {
        ui.open(.{ .width = .grow, .direction = .left_to_right, .padding = .xy(10, 3), .gap = 16, .background_color = theme.toolbar });
        defer ui.close();
        var buf: [96]u8 = undefined;
        const b = &ed.buffer;
        ui.text(std.fmt.bufPrint(&buf, "Ln {d}, Col {d}", .{ b.lineOf(b.cursor) + 1, b.column(b.cursor) + 1 }) catch "", style(ed, theme.dim));
        const count = ed.counts();
        var status: [64]u8 = undefined;
        const summary = if (count.errors + count.warnings == 0)
            "no problems"
        else
            std.fmt.bufPrint(&status, "{d} error{s}, {d} warning{s}", .{ count.errors, if (count.errors == 1) "" else "s", count.warnings, if (count.warnings == 1) "" else "s" }) catch "";
        ui.text(summary, style(ed, if (count.errors > 0) theme.error_ink else if (count.warnings > 0) theme.warning_ink else theme.dim));
        ui.empty(.{ .width = .grow });
        ui.text("F12 definition   Ctrl+Space complete   Ctrl+/ comment", style(ed, theme.faint));
    }
    return action;
}

fn tab(ui: *Ui, ed: *const Editor, id: []const u8, label: []const u8, active: bool) bool {
    const lit = ui.isPointerOver(id);
    ui.open(.{
        .id = id,
        .padding = .xy(10, 3),
        .corner_radius = .all(3),
        .cursor = .pointing_hand,
        .background_color = if (active) theme.button else if (lit) theme.button_hover else .transparent,
    });
    defer ui.close();
    ui.text(label, style(ed, if (active) theme.ink else theme.dim));
    return ui.justReleased();
}

/// The script's outline: each declaration, its members under it. Returns
/// where the one clicked is.
fn members(ui: *Ui, ed: *Editor) ?u32 {
    var clicked: ?u32 = null;
    ui.open(.{
        .id = "members",
        .width = .fixed(26 * ed.metrics.advance),
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .xy(6, 6),
        .background_color = theme.panel,
        .clip = .{ .horizontal = true, .vertical = true, .scroll_y = true, .scrollbar = .{} },
    });
    defer ui.close();
    ui.open(.{ .padding = .trbl(0, 0, 4, 4) });
    ui.text("Members", style(ed, theme.dim));
    ui.close();
    var index: usize = 0;
    for (ed.symbols) |s| {
        if (member(ui, ed, s, 0, &index)) |at| clicked = at;
        for (s.children) |child| if (member(ui, ed, child, 1, &index)) |at| {
            clicked = at;
        };
    }
    return clicked;
}

fn member(ui: *Ui, ed: *Editor, s: service.Symbol, depth: u16, index: *usize) ?u32 {
    var name: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&name, "member-{d}", .{index.*}) catch "member";
    index.* += 1;
    const clicked = ui.isElementReleased(id);
    ui.open(.{
        .id = id,
        .width = .grow,
        .direction = .left_to_right,
        .padding = .trbl(1, 4, 1, 4 + depth * 14),
        .gap = 6,
        .corner_radius = .all(3),
        .cursor = .pointing_hand,
        .background_color = if (ui.isPointerOver(id)) theme.button_hover else .transparent,
    });
    defer ui.close();
    const letter, const color = theme.kind(s.kind);
    ui.text(letter, style(ed, color));
    ui.text(s.name, style(ed, theme.ink));
    return if (clicked) s.span.start else null;
}

fn problems(ui: *Ui, ed: *Editor) ?u32 {
    var clicked: ?u32 = null;
    ui.open(.{
        .id = "problems",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .xy(8, 4),
        .clip = .{ .horizontal = true, .vertical = true, .scroll_y = true, .scrollbar = .{} },
    });
    defer ui.close();
    if (ed.problems.len == 0) {
        ui.text("Nothing is wrong.", style(ed, theme.dim));
        return null;
    }
    for (ed.problems, 0..) |p, i| {
        var name: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&name, "problem-{d}", .{i}) catch "problem";
        if (ui.isElementReleased(id)) clicked = p.start;
        ui.open(.{
            .id = id,
            .width = .grow,
            .direction = .left_to_right,
            .padding = .xy(4, 1),
            .gap = 10,
            .cursor = .pointing_hand,
            .background_color = if (ui.isPointerOver(id)) theme.button_hover else .transparent,
        });
        defer ui.close();
        const is_error = p.severity == .@"error";
        ui.text(if (is_error) "error" else "warning", style(ed, if (is_error) theme.error_ink else theme.warning_ink));
        var where: [24]u8 = undefined;
        ui.text(std.fmt.bufPrint(&where, "{d}:{d}", .{ p.line + 1, p.column + 1 }) catch "", style(ed, theme.dim));
        ui.text(p.message, style(ed, theme.ink));
    }
    return clicked;
}

fn output(ui: *Ui, ed: *Editor, runner: *Runner) void {
    ui.open(.{
        .id = "output",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .xy(8, 4),
        .clip = .{ .horizontal = true, .vertical = true, .scroll_y = true, .scrollbar = .{} },
    });
    defer ui.close();
    if (runner.lines.items.len == 0) {
        ui.text("Press F5 to run the script; what it prints shows here.", style(ed, theme.dim));
        return;
    }
    for (runner.lines.items) |l| {
        ui.open(.{ .width = .grow, .direction = .left_to_right, .height = .fixed(ed.metrics.line_height) });
        defer ui.close();
        ui.text(l.text, style(ed, switch (l.kind) {
            .output => theme.ink,
            .err => theme.error_ink,
            .info => theme.accent,
        }));
    }
}
