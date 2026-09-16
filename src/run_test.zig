// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;

const diag = @import("diag.zig");
const Vm = @import("vm/Vm.zig");
const Compiler = @import("compile/Compiler.zig");
const call = @import("vm/call.zig");
const panic = @import("vm/panic.zig");

fn runSource(source: []const u8, out: *std.Io.Writer.Allocating) !void {
    const vm = try Vm.create(testing.allocator, .{ .out = &out.writer });
    defer vm.destroy();
    var diags: diag.Diagnostics = .init(testing.allocator);
    defer diags.deinit();
    const module = Compiler.compileModule(vm, "test.flux", source, &diags) catch |err| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try diag.render.all(&buf.writer, &vm.sources, &diags, .{});
        std.debug.print("{s}\n", .{buf.written()});
        return err;
    };
    call.runModule(vm, module) catch |err| {
        if (vm.panic) |*p| {
            var buf: std.Io.Writer.Allocating = .init(testing.allocator);
            defer buf.deinit();
            try panic.render(&buf.writer, vm, p, .{});
            std.debug.print("{s}\n", .{buf.written()});
        }
        return err;
    };
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try runSource(source, &out);
    try testing.expectEqualStrings(expected, out.written());
}

test "hello" {
    try expectOutput("print(\"hello\", 1 + 2);", "hello 3\n");
}

test "a budget stops a runaway loop with a panic, and the VM goes on" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("loop.flux", "fn spin() { var n = 0; while (true) { n += 1; } }\nfn fine() int { var t = 0; for (0..10) |i| t += i; return t; }");
    try vm.run(m);
    vm.setBudget(1000);
    try testing.expectError(error.Panic, vm.callName(m, "spin", &.{}));
    try testing.expectEqualStrings("the script ran past its budget of 1000 loop rounds", vm.panic.?.message);
    try testing.expectEqualStrings("spin", vm.panic.?.trace[0].function);
    vm.clearPanic();
    try testing.expectEqual(@as(i64, 45), (try vm.callName(m, "fine", &.{})).asInt());
    vm.setBudget(null);
    vm.interrupt();
    try testing.expectError(error.Panic, vm.callName(m, "spin", &.{}));
    try testing.expectEqualStrings("the host stopped the script", vm.panic.?.message);
    vm.clearPanic();
    try testing.expectEqual(@as(i64, 45), (try vm.callName(m, "fine", &.{})).asInt());
}

test "a heap limit refuses what would pass it" {
    const vm = try Vm.create(testing.allocator, .{ .max_bytes = 256 * 1024 });
    defer vm.destroy();
    const m = try vm.compile("grow.flux", "fn grow() { var all: [string] = []; for (0..100000) |i| all.push(f\"item number {i}\"); }");
    try vm.run(m);
    try testing.expectError(error.OutOfMemory, vm.callName(m, "grow", &.{}));
}

test "a panic inside a native points at the call" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const source = "fn f() {\n    assert(1 > 2, \"no\");\n}";
    const m = try vm.compile("n.flux", source);
    try vm.run(m);
    try testing.expectError(error.Panic, vm.callName(m, "f", &.{}));
    const p = vm.panic.?;
    try testing.expectEqualStrings("assert", p.trace[0].function);
    const span = p.trace[1].span;
    try testing.expectEqualStrings("assert(1 > 2, \"no\")", source[span.start..span.end]);
}

test "a function value gives back what its type says, or panics" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("f.flux",
        \\fn pass(x: any) any { return x; }
        \\var f: fn() int = pass(|| "text");
        \\fn call_it() int { return f() + 1; }
    );
    try vm.run(m);
    try testing.expectError(error.Panic, vm.callName(m, "call_it", &.{}));
    try testing.expect(std.mem.indexOf(u8, vm.panic.?.message, "int") != null);
    vm.clearPanic();
}

test "names longer than any interned string still find their functions and fields" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("long.flux",
        \\struct Settings { var the_rather_long_name_of_a_setting_that_matters: int = 7; }
        \\fn a_function_whose_name_is_longer_than_forty_characters(s: any) int {
        \\    return s.the_rather_long_name_of_a_setting_that_matters;
        \\}
        \\fn run_it() int { return a_function_whose_name_is_longer_than_forty_characters(Settings{}); }
    );
    try vm.run(m);
    try testing.expectEqual(@as(i64, 7), (try vm.callName(m, "run_it", &.{})).asInt());
    try testing.expect(vm.get(m, "a_function_whose_name_is_longer_than_forty_characters") != null);
}
