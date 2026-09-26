// SPDX-License-Identifier: BSD-2-Clause

//! A small IDE for Flux, on fluxion-ui: the language service under an
//! editor.
//!
//! ```bash
//! zig build ide                       an untitled script to try things in
//! zig build ide -- game.flux          a file
//! ```
//!
//! Type, and what could come next is offered - locals first, then what the
//! file declares, then what is built in; after a `.` the members of what is
//! before it. Resting the mouse on a name shows what it is; inside a call's
//! parentheses its parameters show, the current one lit. Mistakes are
//! underlined as they are made and listed under the code. F12, or ctrl and
//! a click, goes to where a name is declared. F5 runs the script, and
//! saving while it runs puts the new code in while it goes on.
//!
//! Its window is fluxion-platform's, its GPU fluxion-rhi's, its font a
//! monospaced one of the system's, read with fluxion-font.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("fluxion_platform");
const rhi = @import("fluxion_rhi");
const font = @import("fluxion_font");
const ui_lib = @import("fluxion_ui");
const render = @import("fluxion_ui_rhi");
const flux = @import("fluxion_script");
const code = @import("fluxion_code");
const Flux = @import("fluxion_script_code").Flux;

const Code = code.Document;
const Runner = @import("Runner.zig");
const panels = @import("panels.zig");
const theme = @import("theme.zig");

const Ui = ui_lib.Ui;

const welcome =
    \\// Welcome to Flux. Type, and completions follow; rest the mouse on a
    \\// name to see what it is. F5 runs this, and Ctrl+S while it runs puts
    \\// the new code in while it goes on: change `greeting` and save.
    \\const math = @import("math");
    \\
    \\/// A ball, rolling.
    \\struct Ball {
    \\    var pos: vec2 = vec2(0, 0);
    \\    var vel: vec2 = vec2(3, 4);
    \\
    \\    /// Moves it on by `dt` seconds.
    \\    fn step(self, dt: float) {
    \\        self.pos += self.vel * dt;
    \\    }
    \\}
    \\
    \\fn greeting() string {
    \\    return "hello";
    \\}
    \\
    \\fn roll() {
    \\    var ball = Ball{};
    \\    var n = 0;
    \\    while (true) {
    \\        await wait(1.0);
    \\        ball.step(1.0);
    \\        n += 1;
    \\        print(f"{greeting()} {n}: {ball.pos}, {math.sqrt(ball.pos.x):.2}");
    \\    }
    \\}
    \\
    \\roll();
    \\
;

/// Where the system keeps a monospaced font, most likely first.
const fonts = switch (builtin.os.tag) {
    .windows => [_][]const u8{ "C:/Windows/Fonts/consola.ttf", "C:/Windows/Fonts/DejaVuSansMono.ttf", "C:/Windows/Fonts/cour.ttf" },
    .macos => [_][]const u8{ "/System/Library/Fonts/Supplemental/Courier New.ttf", "/Library/Fonts/Courier New.ttf", "/System/Library/Fonts/Supplemental/Andale Mono.ttf" },
    else => [_][]const u8{ "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf" },
};

/// How the layout asks the font how wide a run is.
const Measured = struct {
    face: font.Font,

    fn measure(context: ?*const anyopaque, run: []const u8, style: ui_lib.TextStyle) ui_lib.text.Size {
        const self: *const Measured = @ptrCast(@alignCast(context.?));
        const scaled = self.face.at(@floatFromInt(style.font_size));
        const height = if (style.line_height > 0) @as(f32, @floatFromInt(style.line_height)) else scaled.lineHeight();
        return .{ .width = scaled.measure(run) catch 0, .height = height };
    }

    fn lineHeight(context: ?*const anyopaque, style: ui_lib.TextStyle) f32 {
        const self: *const Measured = @ptrCast(@alignCast(context.?));
        if (style.line_height > 0) return @floatFromInt(style.line_height);
        return self.face.at(@floatFromInt(style.font_size)).lineHeight();
    }
};

fn getProcAddress(context: *anyopaque, name: [*:0]const u8) ?rhi.types.GlProc {
    const win: *platform.Window = @ptrCast(@alignCast(context));
    return win.getProcAddress(name);
}

fn swapBuffers(context: *anyopaque) void {
    const win: *platform.Window = @ptrCast(@alignCast(context));
    win.swapBuffers() catch {};
}

fn framebufferSize(context: *anyopaque) [2]u32 {
    const win: *platform.Window = @ptrCast(@alignCast(context));
    return win.framebufferSize();
}

/// Scripts analysed by the editor get `os`, as the ones it runs do.
fn giveOs(context: ?*anyopaque, vm: *flux.Vm) anyerror!void {
    try flux.os.install(vm, @ptrCast(@alignCast(context.?)));
}

/// A key for the find bar's field, while it has the keys. Whether it took it.
fn fieldKey(ui: *Ui, editor: *Code, k: platform.event.KeyEvent, ctrl: bool, letter: platform.Key) bool {
    const shift = k.mods.shift;
    const action: ui_lib.text_input.Action = switch (k.key) {
        .left => .moveTo(if (ctrl) .word_left else .left, shift),
        .right => .moveTo(if (ctrl) .word_right else .right, shift),
        .home => .moveTo(.start, shift),
        .end => .moveTo(.end, shift),
        .backspace => if (ctrl) .backspace_word else .backspace,
        .delete => if (ctrl) .delete_word else .delete,
        .enter, .kp_enter => .submit,
        .escape => {
            editor.closeFind();
            ui.setFocus("");
            return true;
        },
        .f3 => {
            _ = editor.findNext(!shift);
            return true;
        },
        else => if (ctrl and letter == .a) .select_all else if (ctrl and letter == .z) .undo else if (ctrl and letter == .y) .redo else return false,
    };
    _ = ui.textAction(action);
    return true;
}

/// What a key means to the editor, when it means anything.
fn editorKey(k: platform.event.KeyEvent) ?code.Key {
    const letter = if (k.virtual != .unknown) k.virtual else k.key;
    return switch (k.key) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .backspace => .backspace,
        .delete => .delete,
        .enter, .kp_enter => .enter,
        .tab => .tab,
        .escape => .escape,
        .space => .space,
        .f3 => .f3,
        .f12 => .f12,
        .slash => .slash,
        else => switch (letter) {
            .a => .a,
            .f => .f,
            .g => .g,
            .h => .h,
            .y => .y,
            .z => .z,
            else => null,
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var path: ?[]const u8 = null;
    var frames: ?u32 = null;
    var font_path: ?[]const u8 = null;
    var demo: ?Demo = null;
    var i: usize = 1;
    while (i < arguments.len) : (i += 1) {
        const a = arguments[i];
        if (std.mem.eql(u8, a, "--frames") and i + 1 < arguments.len) {
            i += 1;
            frames = std.fmt.parseInt(u32, arguments[i], 10) catch null;
        } else if (std.mem.eql(u8, a, "--font") and i + 1 < arguments.len) {
            i += 1;
            font_path = arguments[i];
        } else if (std.mem.eql(u8, a, "--demo") and i + 1 < arguments.len) {
            i += 1;
            demo = std.meta.stringToEnum(Demo, arguments[i]);
        } else path = a;
    }

    // The window, and the GPU on it.
    var ctx = try platform.Context.init(std.heap.smp_allocator, .{});
    defer ctx.deinit();
    var win = try ctx.createWindow(.{ .title = "Flux IDE", .width = 1280, .height = 820, .gl = .{ .major = 3, .minor = 3, .profile = .core } });
    defer win.destroy();
    try win.makeContextCurrent();
    win.setSwapInterval(.vsync) catch {};
    var device: rhi.Device = try .init(gpa, .{ .backend = .gl, .gl = .{
        .context = &win,
        .get_proc_address = getProcAddress,
        .swap_buffers = swapBuffers,
        .framebuffer_size = framebufferSize,
    } });
    defer device.deinit();
    const fb = win.framebufferSize();
    const surface = try device.createSurface(.{ .native_window = win.native(), .width = fb[0], .height = fb[1] });
    defer device.destroySurface(surface);

    // The font: the first monospaced one found.
    const font_bytes = blk: {
        if (font_path) |p| break :blk try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 << 20));
        for (fonts) |p| {
            break :blk std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 << 20)) catch continue;
        }
        std.log.err("no monospaced font found; give one with --font file.ttf", .{});
        return error.NoFont;
    };
    defer gpa.free(font_bytes);
    var measured: Measured = .{ .face = try .init(font_bytes) };
    var renderer: render.Renderer = try .init(gpa, &device, &measured.face);
    defer renderer.deinit();
    var ui: Ui = .init(gpa);
    defer ui.deinit();
    ui.setMeasurer(.{ .context = &measured, .measureFn = Measured.measure, .lineHeightFn = Measured.lineHeight });

    const scale = win.contentScale()[0];
    const font_size: u16 = @intFromFloat(@round(15 * @max(1, scale)));
    const scaled = measured.face.at(@floatFromInt(font_size));
    // The code measures itself through the interface, as any font needs.
    var ruler: code.Ruler = .{ .ui = &ui, .style = .{ .font_size = font_size } };
    const metrics: code.Metrics = .{
        .font_size = font_size,
        .line_height = @ceil(scaled.lineHeight()),
        .measure = ruler.measure(),
    };

    // The script.
    var os_host: flux.os.Host = .{ .io = io, .args = &.{}, .start = std.Io.Timestamp.now(io, .awake) };
    var file_loader: flux.FileLoader = .{ .io = io };
    var flux_lang: Flux = .{ .options = .{
        .setup = .{ .context = &os_host, .run = giveOs },
        .loader = file_loader.loader(),
        .io = io,
    } };
    const text = if (path) |p| std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(16 << 20)) catch |err| blk: {
        std.log.warn("cannot read {s} ({s}); starting it empty", .{ p, @errorName(err) });
        break :blk try gpa.dupe(u8, "");
    } else try gpa.dupe(u8, welcome);
    defer gpa.free(text);
    var editor: Code = try .init(gpa, path orelse "untitled.flux", text, flux_lang.language(), metrics);
    defer editor.deinit();
    var runner: Runner = .init(gpa, io);
    defer runner.deinit();
    var state: panels.State = .{};

    var pointer_x: f32 = 0;
    var pointer_y: f32 = 0;
    var down = false;
    var pressed = false;
    var wheel: f32 = 0;
    var mods: platform.Mods = .{};
    var focused = true;
    var started = std.Io.Timestamp.now(io, .awake);
    var last = started;
    var drawn: u32 = 0;
    var title_for: u64 = std.math.maxInt(u64);

    // The code has the keyboard until something else is pressed.
    panels.code_view.focus(&ui);
    while (!win.shouldClose()) {
        // Sleep until something happens, unless something is moving.
        const busy = runner.running or editor.hover.offset != null or editor.drag != .none or state.dragging or drawn < 2 or demo != null;
        if (busy) try ctx.pump() else try ctx.pumpWait(500);

        while (ctx.poll()) |event| switch (event) {
            .close => win.setShouldClose(true),
            .focus => |f| focused = f.value,
            .framebuffer_resize => |r| device.resizeSurface(surface, r.width, r.height) catch {},
            .cursor => |c| if (demo != .hover) {
                pointer_x = @floatCast(c.x);
                pointer_y = @floatCast(c.y);
            },
            .mouse_button => |b| if (b.button == .left) {
                down = b.action == .press;
                if (down) pressed = true;
                mods = b.mods;
            },
            .scroll => |s| {
                wheel += @floatCast(s.y);
                mods = s.mods;
            },
            .char => |c| {
                // Ctrl with a letter is a shortcut; ctrl and alt together is
                // AltGr, which types `{`, `[`, `@` on many keyboards.
                if (c.mods.control and !c.mods.alt) continue;
                // The find bar's field, while it has the keys.
                if (ui.wantsKeyboard() and !panels.code_view.hasKeys(&ui)) {
                    var utf8: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c.codepoint, &utf8) catch continue;
                    ui.typeText(utf8[0..n]);
                    continue;
                }
                try editor.typeChar(c.codepoint);
            },
            .key => |k| if (k.action.down()) {
                mods = k.mods;
                const ctrl = k.mods.control and !k.mods.alt;
                const letter = if (k.virtual != .unknown) k.virtual else k.key;
                if (ui.wantsKeyboard() and !panels.code_view.hasKeys(&ui) and fieldKey(&ui, &editor, k, ctrl, letter)) {
                    // Taken by the find bar's field.
                } else if (k.key == .f5) {
                    try runScript(&runner, &editor);
                } else if (ctrl and letter == .s) {
                    save(&editor, &runner, io);
                } else if (ctrl and letter == .o) {
                    _ = ctx.openFileDialog(.{ .window = win, .filters = &.{.{ .name = "Flux scripts", .extensions = &.{"flux"} }} }) catch {};
                } else if (ctrl and (letter == .c or letter == .x)) {
                    const selected = editor.buffer.selectedText();
                    if (selected.len > 0) {
                        ctx.setClipboardText(selected) catch {};
                        if (letter == .x) try editor.buffer.backspace();
                    }
                } else if (ctrl and letter == .v) {
                    const pasted = ctx.clipboardText() catch "";
                    if (pasted.len > 0) {
                        const clean = try std.mem.replaceOwned(u8, gpa, pasted, "\r", "");
                        defer gpa.free(clean);
                        try editor.buffer.insert(clean);
                        editor.reveal = true;
                    }
                } else if (editorKey(k)) |key| {
                    _ = try editor.key(key, .{ .shift = k.mods.shift, .ctrl = ctrl });
                }
            },
            .file_dialog => |answer| if (answer.paths.len > 0) try open(&editor, &runner, answer.paths[0], io),
            else => {},
        };

        const now = std.Io.Timestamp.now(io, .awake);
        const dt: f64 = @as(f64, @floatFromInt(last.durationTo(now).nanoseconds)) / std.time.ns_per_s;
        last = now;
        editor.now = @as(f64, @floatFromInt(started.durationTo(now).nanoseconds)) / std.time.ns_per_s;
        if (demo) |d| if (drawn == 8) try play(d, &editor, &runner, &pointer_x, &pointer_y);
        runner.update(dt);

        // The mouse, against where everything was last frame.
        ui.setPointer(pointer_x, pointer_y, down);
        ui.tick(@floatCast(dt));
        if (pressed and ui.isPointerOver("splitter")) state.dragging = true;
        if (!down) state.dragging = false;
        if (state.dragging) {
            const fb_now = win.framebufferSize();
            state.panel_height = std.math.clamp(@as(f32, @floatFromInt(fb_now[1])) - pointer_y - 30, 60, @as(f32, @floatFromInt(fb_now[1])) - 200);
        } else {
            panels.code_view.pointer(&editor, &ui, .{ .x = pointer_x, .y = pointer_y, .down = down, .pressed = pressed, .mods = .{ .shift = mods.shift, .ctrl = mods.control and !mods.alt } });
        }
        pressed = false;
        if (wheel != 0) {
            if (panels.code_view.under(&ui)) editor.scroll(wheel, mods.shift) else _ = ui.scrollHovered(0, -wheel * 40);
            wheel = 0;
        }
        editor.refresh();
        if (editor.takeRequest()) |request| {
            defer gpa.free(request.path);
            try open(&editor, &runner, request.path, io);
            editor.select(request.start, request.end);
        }

        // The frame.
        const size_fb = win.framebufferSize();
        const size: ui_lib.Dimensions = .init(@floatFromInt(size_fb[0]), @floatFromInt(size_fb[1]));
        ui.begin(.{ .size = size });
        const action = panels.shell(&ui, &editor, &runner, &state, focused);
        const commands = try ui.end();
        panels.code_view.measure(&editor, &ui, 1);
        win.setCursorShape(switch (ui.cursor()) {
            .arrow => .arrow,
            .ibeam => .ibeam,
            .crosshair => .crosshair,
            .pointing_hand => .pointing_hand,
            .resize_ew => .resize_ew,
            .resize_ns => .resize_ns,
            .resize_nwse => .resize_nwse,
            .resize_nesw => .resize_nesw,
            .resize_all => .resize_all,
            .not_allowed => .not_allowed,
        }) catch {};
        try renderer.draw(.{ .surface = surface }, size, commands, theme.window);
        try device.present(surface);
        if (runner.grew) {
            runner.grew = false;
            ui.scrollTo("output", 0, std.math.floatMax(f32) / 2);
            state.tab = .output;
        }

        switch (action) {
            .none => {},
            .run => try runScript(&runner, &editor),
            .stop => runner.stop(true),
            .save => save(&editor, &runner, io),
            .open => _ = ctx.openFileDialog(.{ .window = win, .filters = &.{.{ .name = "Flux scripts", .extensions = &.{"flux"} }} }) catch {},
            .jump => |at| {
                editor.buffer.moveTo(at, false);
                editor.reveal = true;
                editor.closePopups();
            },
        }

        // The file's name, and whether it has changed, in the title bar.
        const version = editor.buffer.version ^ editor.buffer.saved;
        if (version != title_for) {
            title_for = version;
            var title: [320]u8 = undefined;
            win.setTitle(std.fmt.bufPrint(&title, "{s}{s} - Flux IDE", .{ std.fs.path.basename(editor.path), if (editor.buffer.modified()) " *" else "" }) catch "Flux IDE") catch {};
        }

        drawn += 1;
        if (frames) |limit| if (drawn >= limit) break;
    }
}

/// `--demo NAME`: the editor doing one of its things by itself, a few
/// frames in, for a picture of it.
const Demo = enum { complete, signature, hover, problems, run };

fn play(demo: Demo, ed: *Code, runner: *Runner, x: *f32, y: *f32) !void {
    const b = &ed.buffer;
    const at = struct {
        fn end(e: *Code, needle: []const u8) void {
            const found = std.mem.indexOf(u8, e.buffer.text.items, needle) orelse return;
            e.buffer.moveTo(e.buffer.lineEnd(e.buffer.lineOf(@intCast(found))), false);
        }
    }.end;
    switch (demo) {
        .complete, .signature => {
            at(ed, "var ball = Ball{};");
            _ = try ed.key(.enter, .{});
            for (if (demo == .complete) "ball." else "ball.step(") |c| try ed.typeChar(c);
        },
        .problems => {
            at(ed, "var n = 0;");
            _ = try ed.key(.enter, .{});
            for ("n = \"ten\";") |c| try ed.typeChar(c);
            ed.closePopups();
        },
        .hover => {
            const found: u32 = @intCast(std.mem.indexOf(u8, b.text.items, "Ball{}") orelse return);
            const line: f32 = @floatFromInt(b.lineOf(found) -| ed.top);
            x.* = ed.view[0] + ed.gutter + ed.xOf(found + 2) - ed.left;
            y.* = ed.view[1] + (line + 0.5) * ed.metrics.line_height;
        },
        .run => try runner.start(ed.path, b.text.items),
    }
}

fn runScript(runner: *Runner, editor: *Code) !void {
    try runner.start(editor.path, editor.buffer.text.items);
}

/// Writes the file; while the script runs, its new code goes in too.
fn save(editor: *Code, runner: *Runner, io: std.Io) void {
    const bytes = editor.written(editor.gpa) catch return;
    defer editor.gpa.free(bytes);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = editor.path, .data = bytes }) catch |err| {
        runner.say(.err, "cannot save {s}: {s}", .{ editor.path, @errorName(err) });
        return;
    };
    editor.markSaved();
    if (runner.running) runner.reload(editor.buffer.text.items);
}

/// Another file in the editor - unless this one has changes, which are
/// not thrown away.
fn open(editor: *Code, runner: *Runner, path: []const u8, io: std.Io) !void {
    if (editor.buffer.modified()) {
        runner.say(.err, "{s} has changes: save it first, then open {s}", .{ std.fs.path.basename(editor.path), std.fs.path.basename(path) });
        return;
    }
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, editor.gpa, .limited(16 << 20)) catch |err| {
        runner.say(.err, "cannot open {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    defer editor.gpa.free(text);
    try editor.load(path, text);
}

test {
    _ = Runner;
}
