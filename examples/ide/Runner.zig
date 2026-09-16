// SPDX-License-Identifier: BSD-2-Clause

//! Runs the script being edited, in a VM of its own: what it prints kept
//! for the output panel, its tasks moved on every frame, and - saved while
//! it runs - its new code put in while it goes on, the way `flux run
//! --watch` does. A loop that never ends stops at a budget of rounds with
//! a panic, rather than freezing the editor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flux = @import("fluxion_script");

const Runner = @This();

pub const Kind = enum { output, err, info };

pub const Line = struct { text: []u8, kind: Kind };

const max_lines = 2000;
const budget = 20_000_000;

gpa: Allocator,
io: std.Io,
vm: ?*flux.Vm = null,
module: ?*flux.object.Module = null,
out: std.Io.Writer.Allocating,
lines: std.ArrayList(Line) = .empty,
/// Printed, and not yet ended by a line break.
partial: std.ArrayList(u8) = .empty,
host: flux.os.Host,
loader: flux.FileLoader,
/// Whether a task is waiting on the clock.
running: bool = false,
/// Set when lines were added; the panel scrolls down to them.
grew: bool = false,

pub fn init(gpa: Allocator, io: std.Io) Runner {
    return .{
        .gpa = gpa,
        .io = io,
        .out = .init(gpa),
        .host = .{ .io = io, .args = &.{}, .start = std.Io.Timestamp.now(io, .awake) },
        .loader = .{ .io = io },
    };
}

pub fn deinit(r: *Runner) void {
    if (r.vm) |vm| vm.destroy();
    r.out.deinit();
    for (r.lines.items) |l| r.gpa.free(l.text);
    r.lines.deinit(r.gpa);
    r.partial.deinit(r.gpa);
}

pub fn clear(r: *Runner) void {
    for (r.lines.items) |l| r.gpa.free(l.text);
    r.lines.clearRetainingCapacity();
}

/// Text, a line for each line break in it; what follows the last waits for
/// the rest of its line.
fn add(r: *Runner, kind: Kind, text: []const u8) void {
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            r.keep(rest) catch {};
            return;
        };
        r.keep(rest[0..nl]) catch return;
        rest = rest[nl + 1 ..];
        if (r.lines.items.len == max_lines) r.gpa.free(r.lines.orderedRemove(0).text);
        const owned = r.gpa.dupe(u8, std.mem.trimEnd(u8, r.partial.items, "\r")) catch return;
        r.partial.clearRetainingCapacity();
        r.lines.append(r.gpa, .{ .text = owned, .kind = kind }) catch r.gpa.free(owned);
        r.grew = true;
    }
}

/// Printed text into the line being made, a tab as four spaces - the way
/// the editor reads one.
fn keep(r: *Runner, text: []const u8) Allocator.Error!void {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\t')) |tab| {
        try r.partial.appendSlice(r.gpa, rest[0..tab]);
        try r.partial.appendNTimes(r.gpa, ' ', 4);
        rest = rest[tab + 1 ..];
    }
    try r.partial.appendSlice(r.gpa, rest);
}

/// A line of its own, not from the script.
pub fn say(r: *Runner, kind: Kind, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    r.add(kind, std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch "(a message too long to show)\n");
}

/// What the script printed since this was last asked.
fn drain(r: *Runner) void {
    const text = r.out.written();
    if (text.len > 0) r.add(.output, text);
    r.out.clearRetainingCapacity();
}

fn report(r: *Runner, kind: Kind, comptime write: anytype, args: anytype) void {
    var text: std.Io.Writer.Allocating = .init(r.gpa);
    defer text.deinit();
    @call(.auto, write, args ++ .{ &text.writer, flux.diag.render.Options{} }) catch {};
    r.add(kind, text.written());
    if (text.written().len > 0 and text.written()[text.written().len - 1] != '\n') r.add(kind, "\n");
}

fn taskPanic(vm: *flux.Vm, p: *const flux.Vm.Panic) void {
    const r: *Runner = @ptrCast(@alignCast(vm.host.?));
    if (flux.os.exiting(vm)) return;
    r.drain();
    var text: std.Io.Writer.Allocating = .init(r.gpa);
    defer text.deinit();
    flux.renderPanic(&text.writer, vm, p, .{}) catch {};
    r.add(.err, text.written());
}

/// Compiles and runs `source` afresh, stopping what ran before.
pub fn start(r: *Runner, path: []const u8, source: []const u8) Allocator.Error!void {
    r.stop(false);
    r.say(.info, "running {s}", .{std.fs.path.basename(path)});
    const vm = try flux.Vm.create(r.gpa, .{ .out = &r.out.writer, .loader = r.loader.loader(), .io = r.io, .on_task_panic = taskPanic });
    r.vm = vm;
    vm.host = r;
    r.host.exit_code = null;
    try flux.os.install(vm, &r.host);
    const module = vm.compile(path, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CompileFailed => {
            r.report(.err, flux.Vm.writeDiagnostics, .{vm});
            r.stop(false);
            return;
        },
    };
    r.module = module;
    vm.setBudget(budget);
    vm.run(module) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Panic => r.panicked(),
    };
    r.drain();
    r.running = r.vm != null and vm.scheduler.timers.items.len > 0;
    if (!r.running and r.vm != null) r.say(.info, "finished", .{});
}

fn panicked(r: *Runner) void {
    const vm = r.vm orelse return;
    r.drain();
    if (r.host.exit_code) |code| {
        r.say(.info, "exited with {d}", .{code});
    } else {
        r.report(.err, flux.Vm.writePanic, .{vm});
    }
    vm.clearPanic();
    r.stop(false);
}

/// Moves the script's time on, waking the tasks that are due.
pub fn update(r: *Runner, dt: f64) void {
    const vm = r.vm orelse return;
    if (!r.running) return;
    vm.setBudget(budget);
    vm.update(dt) catch {
        r.panicked();
        return;
    };
    r.drain();
    if (r.host.exit_code != null) return r.panicked();
    if (vm.scheduler.timers.items.len == 0) {
        r.running = false;
        r.say(.info, "finished", .{});
    }
}

/// The running script's new code, put in while it runs.
pub fn reload(r: *Runner, source: []const u8) void {
    const vm = r.vm orelse return;
    const module = r.module orelse return;
    const done = vm.reload(module, source) catch |err| {
        switch (err) {
            error.CompileFailed => {
                r.say(.err, "not reloaded: the new code has mistakes", .{});
                r.report(.err, flux.Vm.writeDiagnostics, .{vm});
            },
            error.Busy => r.say(.err, "not reloaded: the script is in the middle of something", .{}),
            error.Panic => r.panicked(),
            error.OutOfMemory => r.say(.err, "not reloaded: out of memory", .{}),
        }
        return;
    };
    r.drain();
    if (done.changed) |what| {
        r.say(.info, "reloaded; `{s}` changed shape, so {d} task(s) stopped", .{ what, done.stopped });
    } else {
        r.say(.info, "reloaded, and running on", .{});
    }
}

pub fn stop(r: *Runner, say_so: bool) void {
    if (r.vm) |vm| {
        vm.destroy();
        if (say_so) r.say(.info, "stopped", .{});
    }
    r.vm = null;
    r.module = null;
    r.running = false;
}

test "a script's output is kept a line at a time, and a mistake reported" {
    var r: Runner = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    try r.start("t.flux", "print(\"a\");\nprint(1 + 1);\n");
    try std.testing.expectEqual(@as(usize, 4), r.lines.items.len);
    try std.testing.expectEqualStrings("a", r.lines.items[1].text);
    try std.testing.expectEqualStrings("2", r.lines.items[2].text);
    try std.testing.expectEqual(Kind.info, r.lines.items[3].kind);
    r.clear();
    try r.start("t.flux", "var x: int = \"no\";\n");
    try std.testing.expect(r.lines.items.len > 2);
    try std.testing.expectEqual(Kind.err, r.lines.items[1].kind);
}

test "what a script prints keeps its indentation, a tab as four spaces" {
    var r: Runner = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    try r.start("t.flux", "print(\"  two\");\nprint(\"\\tfour\");\n");
    try std.testing.expectEqualStrings("  two", r.lines.items[1].text);
    try std.testing.expectEqualStrings("    four", r.lines.items[2].text);
}

test "a task goes on across frames, and takes new code when reloaded" {
    var r: Runner = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    const before = "fn word() string { return \"old\"; }\nfn loop() {\n    while (true) {\n        await wait(1.0);\n        print(word());\n    }\n}\nloop();\n";
    try r.start("t.flux", before);
    try std.testing.expect(r.running);
    r.update(1.0);
    try std.testing.expectEqualStrings("old", r.lines.items[r.lines.items.len - 1].text);
    r.reload("fn word() string { return \"new\"; }\nfn loop() {\n    while (true) {\n        await wait(1.0);\n        print(word());\n    }\n}\nloop();\n");
    r.update(1.0);
    try std.testing.expectEqualStrings("new", r.lines.items[r.lines.items.len - 1].text);
    r.stop(true);
    try std.testing.expect(!r.running);
}
