// SPDX-License-Identifier: BSD-2-Clause

//! `flux`: run a script, check it, test it, or look at what it compiles to.

const std = @import("std");
const flux = @import("fluxion_script");
const watch = @import("watch.zig");

const usage =
    \\usage: flux <command> <file.flux> [arguments]
    \\
    \\  run     compile and run the file; the arguments go to `os.args`
    \\  check   compile only and report what is wrong (--json for editors)
    \\  test    run the file's `test "..." { }` blocks
    \\  disasm  show the bytecode each function compiles to
    \\  ast     show the syntax tree
    \\  lsp     answer an editor over the Language Server Protocol, on stdin and stdout
    \\  version print the version
    \\
    \\options: --color, --no-color
    \\         --watch   with run: reload each file the script loaded when it is saved
    \\
;

var stderr_writer: *std.Io.Writer = undefined;
var color = false;

fn reportTaskPanic(vm: *flux.Vm, p: *const flux.Vm.Panic) void {
    if (flux.os.exiting(vm)) return;
    // What the script printed first shows first.
    if (vm.options.out) |w| w.flush() catch {};
    flux.renderPanic(stderr_writer, vm, p, .{ .color = color }) catch {};
    stderr_writer.flush() catch {};
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);

    // Streaming: a positional writer on a file the output is sent to starts
    // at its offset 0, over what was there and over the other stream.
    var out_buf: [16 * 1024]u8 = undefined;
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    var err_buf: [4096]u8 = undefined;
    var err_file: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    stderr_writer = &err_file.interface;
    defer out.flush() catch {};
    defer stderr_writer.flush() catch {};

    color = std.Io.File.stderr().supportsAnsiEscapeCodes(io) catch false;
    var positional: std.ArrayList([]const u8) = .empty;
    var json = false;
    var watching = false;
    for (all_args[1..]) |a| {
        if (positional.items.len < 2 and std.mem.startsWith(u8, a, "--")) {
            if (std.mem.eql(u8, a, "--color")) color = true else if (std.mem.eql(u8, a, "--no-color")) color = false else if (std.mem.eql(u8, a, "--json")) json = true else if (std.mem.eql(u8, a, "--watch")) watching = true else {
                try stderr_writer.print("flux: unknown option `{s}`\n\n{s}", .{ a, usage });
                return 64;
            }
            continue;
        }
        try positional.append(arena, a);
    }
    if (positional.items.len == 0) {
        try stderr_writer.writeAll(usage);
        return 64;
    }
    const command = positional.items[0];
    if (std.mem.eql(u8, command, "version")) {
        try out.writeAll("flux 0.1.0\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "help")) {
        try out.writeAll(usage);
        return 0;
    }
    if (std.mem.eql(u8, command, "lsp")) {
        var in_buf: [64 * 1024]u8 = undefined;
        var in_file = std.Io.File.stdin().readerStreaming(io, &in_buf);
        var server: flux.lsp.Server = .init(gpa, io, out);
        defer server.deinit();
        return server.run(&in_file.interface);
    }
    if (positional.items.len < 2) {
        try stderr_writer.print("flux {s}: which file?\n\n{s}", .{ command, usage });
        return 64;
    }
    const path = positional.items[1];
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |err| {
        try stderr_writer.print("flux: cannot read `{s}`: {s}\n", .{ path, @errorName(err) });
        return 66;
    };
    defer gpa.free(source);

    if (std.mem.eql(u8, command, "ast")) {
        var tree_arena: std.heap.ArenaAllocator = .init(gpa);
        defer tree_arena.deinit();
        var sources: flux.diag.Sources = .init(gpa);
        defer sources.deinit();
        var diags: flux.diag.Diagnostics = .init(gpa);
        defer diags.deinit();
        const file = try sources.add(path, source);
        const tree = try flux.syntax.parse.parse(tree_arena.allocator(), gpa, source, file, &diags);
        try flux.syntax.dump.module(out, tree);
        try out.writeByte('\n');
        try flux.diag.render.all(stderr_writer, &sources, &diags, .{ .color = color });
        return if (diags.failed()) 1 else 0;
    }

    var loader: flux.FileLoader = .{ .io = io };
    const vm = try flux.Vm.create(gpa, .{
        .out = out,
        .loader = loader.loader(),
        .io = io,
        .on_task_panic = reportTaskPanic,
    });
    defer vm.destroy();
    var host: flux.os.Host = .{ .io = io, .args = positional.items[1..], .start = std.Io.Timestamp.now(io, .awake) };
    try flux.os.install(vm, &host);

    const module = vm.compile(path, source) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.CompileFailed => {
            try report(vm, json);
            return 1;
        },
    };
    if (vm.diagnostics.warnings > 0) try report(vm, json);

    if (std.mem.eql(u8, command, "check")) return 0;
    if (std.mem.eql(u8, command, "disasm")) {
        try flux.disasm.module(out, vm, module);
        return 0;
    }
    if (std.mem.eql(u8, command, "run")) {
        if (watching) return watch.run(vm, module, &host, io, .{ .err = stderr_writer, .color = color });
        return runModule(vm, module, &host, io);
    }
    if (std.mem.eql(u8, command, "test")) return runTests(vm, module, out);
    try stderr_writer.print("flux: unknown command `{s}`\n\n{s}", .{ command, usage });
    return 64;
}

fn report(vm: *flux.Vm, json: bool) !void {
    if (json) {
        try flux.diag.render.jsonLines(stderr_writer, &vm.sources, &vm.diagnostics);
    } else {
        try vm.writeDiagnostics(stderr_writer, .{ .color = color });
    }
}

fn stopped(vm: *flux.Vm, host: *flux.os.Host) u8 {
    if (host.exit_code) |code| {
        vm.clearPanic();
        return code;
    }
    if (vm.options.out) |w| w.flush() catch {};
    vm.writePanic(stderr_writer, .{ .color = color }) catch {};
    vm.clearPanic();
    return 2;
}

/// Runs the module, then keeps time for its tasks until none is waiting
/// on the clock.
fn runModule(vm: *flux.Vm, module: *flux.object.Module, host: *flux.os.Host, io: std.Io) !u8 {
    vm.run(module) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Panic => return stopped(vm, host),
    };
    var last = std.Io.Timestamp.now(io, .awake);
    while (vm.scheduler.timers.items.len > 0) {
        const wait = vm.scheduler.timers.items[0].wake_at - vm.scheduler.time;
        if (wait > 0) {
            try vm.options.out.?.flush();
            io.sleep(.fromNanoseconds(@intFromFloat(wait * std.time.ns_per_s)), .awake) catch {};
        }
        const now = std.Io.Timestamp.now(io, .awake);
        const dt = @as(f64, @floatFromInt(last.durationTo(now).nanoseconds)) / std.time.ns_per_s;
        last = now;
        vm.update(@max(dt, wait)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Panic => return stopped(vm, host),
        };
        if (host.exit_code) |code| return code;
    }
    return 0;
}

fn runTests(vm: *flux.Vm, module: *flux.object.Module, out: *std.Io.Writer) !u8 {
    vm.run(module) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Panic => {
            try out.writeAll("the file's own code failed before its tests could run\n");
            try out.flush();
            vm.writePanic(stderr_writer, .{ .color = color }) catch {};
            return 2;
        },
    };
    const tests = module.tests.items;
    var failed: usize = 0;
    for (tests, 1..) |t, i| {
        try out.print("{d}/{d} {s}...", .{ i, tests.len, t.name.bytes() });
        if (vm.call(.fromObj(.function, &t.function.obj), &.{})) |_| {
            try out.writeAll("OK\n");
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            error.Panic => {
                failed += 1;
                try out.writeAll("FAIL\n");
                try out.flush();
                vm.writePanic(stderr_writer, .{ .color = color }) catch {};
                stderr_writer.flush() catch {};
                vm.clearPanic();
            },
        }
    }
    if (tests.len == 0) try out.writeAll("no tests\n") else if (failed == 0) try out.print("all {d} passed\n", .{tests.len}) else try out.print("{d} passed; {d} failed\n", .{ tests.len - failed, failed });
    return if (failed > 0) 3 else 0;
}
