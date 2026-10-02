// SPDX-License-Identifier: BSD-2-Clause

//! Work of the host's that ends later, as a task a script awaits: typed as
//! the host says it ends, woken when the host ends it, an error caught
//! where it is awaited. And the `hash` and `url` modules a web API needs.

const std = @import("std");
const testing = std.testing;

const reflect = @import("fluxion_reflect");
const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");
const bridge = @import("reflect.zig");
const service = @import("service.zig");

const Answer = extern struct {
    status: i32 = 0,
};

/// Asks, and answers later: as a web client would.
const Web = struct {
    asked: std.ArrayList(Value) = .empty,

    pub const reflect_fields = .{ .asked = .{reflect.attr.Hidden{}} };
    pub const reflect_methods = .{
        .get = .{ reflect.attr.Params{ .names = &.{ "vm", "url" } }, bridge.Pending.of(Answer, true), reflect.attr.Doc{ .text = "Asks for the page." } },
    };

    pub fn get(web: *Web, vm: *Vm, url: []const u8) Vm.Error!Value {
        _ = url;
        const task = try vm.newHostTask();
        try vm.hold(task);
        try web.asked.append(vm.gpa, task);
        return task;
    }

    fn answer(web: *Web, vm: *Vm, i: usize, status: i32) !void {
        const made = try vm.newHandle(Answer);
        const held: *Answer = @ptrCast(@alignCast(made.as(object.Handle).value.ptr));
        held.status = status;
        try vm.pushRoot(made);
        defer vm.popRoot();
        try vm.finishTask(web.asked.items[i], made);
        // Ended twice, it keeps what the first end gave it.
        try vm.finishTask(web.asked.items[i], .int(1));
        vm.release(web.asked.items[i]);
    }

    fn refuse(web: *Web, vm: *Vm, i: usize) !void {
        try vm.failTask(web.asked.items[i], "Timeout", "no answer");
        vm.release(web.asked.items[i]);
    }
};

const source =
    \\const hash = @import("hash");
    \\const url = @import("url");
    \\var got = 0;
    \\var why = "";
    \\var kept: any = null;
    \\fn go() {
    \\    const a = await web.get("https://example.com") catch |err| {
    \\        why = err.name;
    \\        return;
    \\    };
    \\    got = a.status;
    \\}
    \\fn later() {
    \\    const t = web.get("https://example.com/later");
    \\    got = -1;
    \\    kept = await t;
    \\}
    \\fn digests() [string] {
    \\    return [hash.md5("abc"), hash.sha1("abc"), hash.sha256("abc"), hash.hmac_sha256("key", "The quick brown fox jumps over the lazy dog")];
    \\}
    \\fn urls() [string] {
    \\    return [url.encode("a b&c=é~"), url.decode("a%20b%26c%3D%C3%A9~%zz+"), url.query({"b": 2, "a": "x y", "c": true})];
    \\}
;

test "a host's task is awaited for what the host ends it with, kept to await later, or caught when it fails" {
    var web: Web = .{};
    defer web.asked.deinit(testing.allocator);
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    inline for (.{ Web, Answer }) |T| try vm.declareType(reflect.typeOf(T));
    try vm.defineGlobal("web", try vm.handle(&web), null);
    const m = try vm.load("web.flux", source);

    _ = try vm.callName(m, "go", &.{});
    try testing.expectEqual(@as(i64, 0), vm.get(m, "got").?.asInt());
    try web.answer(vm, 0, 200);
    try testing.expectEqual(@as(i64, 200), vm.get(m, "got").?.asInt());

    _ = try vm.callName(m, "go", &.{});
    try web.refuse(vm, 1);
    try testing.expectEqualStrings("Timeout", vm.get(m, "why").?.as(object.String).bytes());

    _ = try vm.callName(m, "later", &.{});
    try testing.expectEqual(@as(i64, -1), vm.get(m, "got").?.asInt());
    try web.answer(vm, 2, 404);
    const kept = vm.reflectOf(vm.get(m, "kept").?).?;
    try testing.expectEqual(@as(i32, 404), kept.get(Answer).?.status);

    const digests = vm.get(m, "digests").?;
    const d = (try vm.call(digests, &.{})).as(object.List).items.items;
    try testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", d[0].as(object.String).bytes());
    try testing.expectEqualStrings("a9993e364706816aba3e25717850c26c9cd0d89d", d[1].as(object.String).bytes());
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", d[2].as(object.String).bytes());
    try testing.expectEqualStrings("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8", d[3].as(object.String).bytes());

    const u = (try vm.callName(m, "urls", &.{})).as(object.List).items.items;
    try testing.expectEqualStrings("a%20b%26c%3D%C3%A9~", u[0].as(object.String).bytes());
    try testing.expectEqualStrings("a b&c=é~%zz+", u[1].as(object.String).bytes());
    try testing.expectEqualStrings("a=x%20y&b=2&c=true", u[2].as(object.String).bytes());
}

fn setup(_: ?*anyopaque, vm: *Vm) anyerror!void {
    inline for (.{ Web, Answer }) |T| try vm.declareType(reflect.typeOf(T));
    try vm.declareGlobal("web", reflect.typeOf(Web), null);
}

const options: service.Options = .{ .setup = .{ .run = setup } };

test "a host's task is typed: awaited it is what the host says it ends with, else a task" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const program =
        \\const hash = @import("hash");
        \\fn wrong() int {
        \\    const a = await web.get("u");
        \\    return a.status;
        \\}
        \\fn notAwaited() int {
        \\    return web.get("u");
        \\}
        \\fn digest() int {
        \\    return hash.md5("x");
        \\}
    ;
    const analysis = try service.Analysis.init(testing.allocator, "web.flux", program, options);
    defer analysis.deinit();
    var got: std.ArrayList([]const u8) = .empty;
    for (analysis.diagnostics.items.items) |d| try got.append(a, d.message);
    try testing.expectEqual(@as(usize, 3), got.items.len);
    try testing.expect(std.mem.indexOf(u8, got.items[0], "!Answer") != null);
    try testing.expect(std.mem.indexOf(u8, got.items[1], "task") != null);
    try testing.expect(std.mem.indexOf(u8, got.items[2], "string") != null);

    const on_get = (try analysis.hover(a, @intCast(std.mem.indexOf(u8, program, "get").? + 1))).?;
    try testing.expectEqualStrings("fn Web.get(url: string) !Answer", on_get.code);
}
