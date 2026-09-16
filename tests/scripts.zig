// SPDX-License-Identifier: BSD-2-Clause

//! Every `.flux` file under `scripts/`, run, and checked against what its
//! comments say it does:
//!
//!     // out: a line it prints, in order
//!     // error: part of a compile error, in order
//!     // warning: part of a warning
//!     // panic: part of the runtime error it stops with
//!     // task panic: part of a panic in a task nothing waited for, in order

const std = @import("std");
const flux = @import("fluxion_script");

const Expect = struct {
    out: std.ArrayList(u8) = .empty,
    errors: std.ArrayList([]const u8) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,
    panic: ?[]const u8 = null,
    task_panics: std.ArrayList([]const u8) = .empty,

    fn deinit(e: *Expect, gpa: std.mem.Allocator) void {
        e.out.deinit(gpa);
        e.errors.deinit(gpa);
        e.warnings.deinit(gpa);
        e.task_panics.deinit(gpa);
    }
};

fn expectations(gpa: std.mem.Allocator, source: []const u8) !Expect {
    var e: Expect = .{};
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const at = std.mem.indexOf(u8, line, "// ") orelse continue;
        const comment = line[at + 3 ..];
        if (std.mem.startsWith(u8, comment, "out: ")) {
            try e.out.appendSlice(gpa, comment[5..]);
            try e.out.append(gpa, '\n');
        } else if (std.mem.eql(u8, comment, "out:")) {
            try e.out.append(gpa, '\n');
        } else if (std.mem.startsWith(u8, comment, "error: ")) {
            try e.errors.append(gpa, comment[7..]);
        } else if (std.mem.startsWith(u8, comment, "warning: ")) {
            try e.warnings.append(gpa, comment[9..]);
        } else if (std.mem.startsWith(u8, comment, "panic: ")) {
            e.panic = comment[7..];
        } else if (std.mem.startsWith(u8, comment, "task panic: ")) {
            try e.task_panics.append(gpa, comment[12..]);
        }
    }
    return e;
}

/// Runs a script twice: as it is, and collecting everything on every
/// allocation, which is how a value nothing roots shows itself.
fn check(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, report: *std.Io.Writer) !bool {
    const source = try dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
    defer gpa.free(source);
    const normal = try checkOnce(gpa, source, name, false, report);
    const stressed = try checkOnce(gpa, source, name, true, report);
    if (normal and !stressed) try report.print("{s}: fails only when the collector runs on every allocation\n", .{name});
    return normal and stressed;
}

const TaskPanics = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList([]const u8) = .empty,

    fn deinit(t: *TaskPanics) void {
        for (t.messages.items) |m| t.gpa.free(m);
        t.messages.deinit(t.gpa);
    }

    fn record(vm: *flux.Vm, p: *const flux.Vm.Panic) void {
        const t: *TaskPanics = @ptrCast(@alignCast(vm.host.?));
        const copy = t.gpa.dupe(u8, p.message) catch return;
        t.messages.append(t.gpa, copy) catch t.gpa.free(copy);
    }
};

fn checkOnce(gpa: std.mem.Allocator, source: []const u8, name: []const u8, stress: bool, report: *std.Io.Writer) !bool {
    var want = try expectations(gpa, source);
    defer want.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var task_panics: TaskPanics = .{ .gpa = gpa };
    defer task_panics.deinit();
    const vm = try flux.Vm.create(gpa, .{ .out = &out.writer, .gc = .{ .stress = stress, .verify = true }, .on_task_panic = TaskPanics.record });
    defer vm.destroy();
    vm.host = &task_panics;
    var diags: flux.diag.Diagnostics = .init(gpa);
    defer diags.deinit();

    var ok = true;
    const module = flux.Compiler.compileModule(vm, name, source, &diags) catch null;
    var got_errors: std.ArrayList([]const u8) = .empty;
    defer got_errors.deinit(gpa);
    var got_warnings: std.ArrayList([]const u8) = .empty;
    defer got_warnings.deinit(gpa);
    for (diags.items.items) |d| switch (d.severity) {
        .@"error" => try got_errors.append(gpa, d.message),
        .warning => try got_warnings.append(gpa, d.message),
        .note => {},
    };
    if (!matches(want.errors.items, got_errors.items) or !matches(want.warnings.items, got_warnings.items)) {
        ok = false;
        try report.print("\n{s}: the diagnostics differ\n", .{name});
        try flux.diag.render.all(report, &vm.sources, &diags, .{});
    }
    if (module) |m| {
        flux.run(vm, m) catch {};
        if (vm.takePanic()) |p| {
            var panic = p;
            defer panic.deinit(gpa);
            if (want.panic == null or std.mem.indexOf(u8, panic.message, want.panic.?) == null) {
                ok = false;
                try report.print("\n{s}: stopped with a panic\n", .{name});
                try flux.renderPanic(report, vm, &panic, .{});
            }
        } else if (want.panic) |p| {
            ok = false;
            try report.print("\n{s}: expected a panic containing \"{s}\"\n", .{ name, p });
        }
        for (0..40) |_| {
            flux.update(vm, 0.25) catch {};
            if (vm.takePanic()) |p| {
                var panic = p;
                defer panic.deinit(gpa);
                ok = false;
                try report.print("\n{s}: a task stopped with a panic\n", .{name});
                try flux.renderPanic(report, vm, &panic, .{});
            }
        }
    }
    if (!matches(want.task_panics.items, task_panics.messages.items)) {
        ok = false;
        try report.print("\n{s}: the panics in tasks differ\n", .{name});
        for (task_panics.messages.items) |m| try report.print("    {s}\n", .{m});
    }
    if (!std.mem.eql(u8, want.out.items, out.written())) {
        ok = false;
        try report.print("\n{s}: the output differs\n--- expected\n{s}--- got\n{s}---\n", .{ name, want.out.items, out.written() });
    }
    return ok;
}

fn matches(want: []const []const u8, got: []const []const u8) bool {
    if (want.len != got.len) return false;
    for (want, got) |w, g| if (std.mem.indexOf(u8, g, w) == null) return false;
    return true;
}

test "every example script compiles without a word from the compiler" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "../examples/scripts", .{ .iterate = true });
    defer dir.close(io);
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var failed: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".flux")) continue;
        const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(source);
        const vm = try flux.Vm.create(gpa, .{});
        defer vm.destroy();
        var host: flux.os.Host = .{ .io = io, .args = &.{}, .start = std.Io.Timestamp.now(io, .awake) };
        try flux.os.install(vm, &host);
        _ = vm.compile(entry.name, source) catch {};
        if (vm.diagnostics.items.items.len > 0) {
            failed += 1;
            try vm.writeDiagnostics(&report.writer, .{});
        }
    }
    if (failed > 0) {
        std.debug.print("{s}\n{d} example scripts had diagnostics\n", .{ report.written(), failed });
        return error.ExamplesFailed;
    }
}

test "every script does what it says" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "scripts", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".flux")) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var failed: usize = 0;
    for (names.items) |name| {
        if (!try check(gpa, io, dir, name, &report.writer)) failed += 1;
    }
    if (failed > 0) {
        std.debug.print("{s}\n{d} of {d} scripts failed\n", .{ report.written(), failed, names.items.len });
        return error.ScriptsFailed;
    }
}
