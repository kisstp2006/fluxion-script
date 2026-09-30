// SPDX-License-Identifier: BSD-2-Clause

//! Images: a module and what it imports saved and loaded again, what an image
//! refuses to be, and what it names when the VM it goes into lacks it. The
//! scripts under `tests/scripts` are each run from an image as well, with
//! their lines and without, and must do what their source did.

const std = @import("std");
const testing = std.testing;

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const image = @import("image.zig");

const gpa = testing.allocator;

/// Files by name, for a loader that gives what it holds: sources in the VM
/// that compiles, images in the one that loads.
const Files = struct {
    items: []const struct { name: []const u8, bytes: []const u8 },

    fn loader(self: *Files) Vm.Loader {
        return .{ .context = self, .load = load };
    }

    fn load(context: ?*anyopaque, allocator: std.mem.Allocator, from: []const u8, path: []const u8) anyerror!Vm.Loader.Loaded {
        _ = from;
        const self: *Files = @ptrCast(@alignCast(context.?));
        for (self.items) |f| if (std.mem.eql(u8, f.name, path)) {
            return .{ .name = try allocator.dupe(u8, f.name), .source = try allocator.dupe(u8, f.bytes) };
        };
        return error.FileNotFound;
    }
};

const shapes_source =
    \\enum Shape {
    \\    circle,
    \\    square,
    \\
    \\    fn corners(self) int {
    \\        if (self == .square) return 4;
    \\        return 0;
    \\    }
    \\}
    \\struct Piece {
    \\    @export @range(1, 10) var size: int = 2;
    \\    var shape: Shape = .circle;
    \\
    \\    fn area(self) int {
    \\        return self.size * self.size;
    \\    }
    \\
    \\    fn make(size: int) Piece {
    \\        return Piece{ .size = size, .shape = .square };
    \\    }
    \\}
    \\fn piece(size: int) Piece {
    \\    return Piece.make(size);
    \\}
    \\fn double(n: int) int {
    \\    return n * 2;
    \\}
    \\const limit = 12;
;

const game_source =
    \\const shapes = @import("shapes.flux");
    \\var made = shapes.piece(3);
    \\fn score() int {
    \\    const all = [made, shapes.piece(2)];
    \\    var total = 0;
    \\    for (all) |each| total += each.area() + each.shape.corners();
    \\    return shapes.double(total) + shapes.limit;
    \\}
;

test "a module that imports another is saved, and loaded with it" {
    var sources: Files = .{ .items = &.{
        .{ .name = "shapes.flux", .bytes = shapes_source },
        .{ .name = "game.flux", .bytes = game_source },
    } };
    const first = try Vm.create(gpa, .{ .loader = sources.loader() });
    defer first.destroy();
    const game = try first.compile("game.flux", game_source);
    const saved_game = try first.saveCompiled(game, gpa, .{});
    defer gpa.free(saved_game);
    const saved_shapes = try first.saveCompiled(first.modules.get("shapes.flux").?, gpa, .{ .lines = false });
    defer gpa.free(saved_shapes);

    // Neither says anything of how it was written.
    try testing.expect(std.mem.indexOf(u8, saved_game, "@import") == null);
    try testing.expect(std.mem.indexOf(u8, saved_shapes, "self.size * self.size") == null);

    var images: Files = .{ .items = &.{
        .{ .name = "shapes.flux", .bytes = saved_shapes },
        .{ .name = "game.flux", .bytes = saved_game },
    } };
    const second = try Vm.create(gpa, .{ .loader = images.loader() });
    defer second.destroy();
    const loaded = try second.load("game.flux", saved_game);
    // 3*3 + 4 and 2*2 + 4, doubled, and the limit.
    try testing.expectEqual(@as(i64, 2 * (9 + 4 + 4 + 4) + 12), (try second.callName(loaded, "score", &.{})).asInt());

    // The struct keeps what the host reads of it.
    const shapes = second.modules.get("shapes.flux").?;
    const piece = second.get(shapes, "Piece").?.as(@import("vm/object.zig").Class);
    try testing.expect(piece.fields[piece.fields.len - 2].exported);
    try testing.expect(piece.fields[piece.fields.len - 2].annotations != null);
}

test "an image made for another instruction set, or damaged, is refused and never read past" {
    const first = try Vm.create(gpa, .{});
    defer first.destroy();
    const m = try first.compile("small.flux",
        \\struct Box { var items: [int] = []; fn add(self, n: int) { self.items.append(n); } }
        \\fn run() int { const b = Box{}; b.add(3); b.add(4); return b.items.len; }
    );
    const saved = try first.saveCompiled(m, gpa, .{});
    defer gpa.free(saved);

    const bent = try gpa.dupe(u8, saved);
    defer gpa.free(bent);
    bent[5] ^= 1; // the instruction set's number
    {
        const vm = try Vm.create(gpa, .{});
        defer vm.destroy();
        try testing.expectError(error.CompileFailed, vm.compile("small.flux", bent));
        try testing.expect(std.mem.indexOf(u8, vm.diagnostics.items.items[0].message, "another version") != null);
    }

    // Cut short anywhere, it is damaged; changed anywhere, it loads or says
    // why, and never reads outside itself doing either.
    for (1..saved.len) |len| {
        const vm = try Vm.create(gpa, .{});
        defer vm.destroy();
        try testing.expectError(error.CompileFailed, vm.compile("small.flux", saved[0..len]));
    }
    for (magic_len..saved.len) |at| {
        @memcpy(bent, saved);
        bent[at] +%= 0x41;
        const vm = try Vm.create(gpa, .{});
        defer vm.destroy();
        _ = vm.compile("small.flux", bent) catch {};
    }
}

const magic_len = image.magic.len;

fn greet(vm: *Vm, args: []Value) Vm.Error!Value {
    _ = args;
    return vm.string("hello");
}

test "what an image uses is found by name, and named when it is not there" {
    const first = try Vm.create(gpa, .{});
    defer first.destroy();
    try first.defineGlobal("greet", try first.native("greet", greet, 0, 0, null), null);
    const m = try first.compile("hello.flux", "fn run() string { return greet(); }");
    const saved = try first.saveCompiled(m, gpa, .{});
    defer gpa.free(saved);

    const with = try Vm.create(gpa, .{});
    defer with.destroy();
    try with.defineGlobal("greet", try with.native("greet", greet, 0, 0, null), null);
    const loaded = try with.load("hello.flux", saved);
    try testing.expectEqualStrings("hello", (try with.callName(loaded, "run", &.{})).as(@import("vm/object.zig").String).bytes());

    const without = try Vm.create(gpa, .{});
    defer without.destroy();
    try testing.expectError(error.CompileFailed, without.compile("hello.flux", saved));
    try testing.expect(std.mem.indexOf(u8, without.diagnostics.items.items[0].message, "`greet`") != null);
}

test "a module that has run is not saved: an image is what compile left" {
    const vm = try Vm.create(gpa, .{});
    defer vm.destroy();
    const m = try vm.load("ran.flux", "var count = 0; count += 1;");
    try testing.expectError(error.Unsaveable, vm.saveCompiled(m, gpa, .{}));
    try testing.expect(std.mem.indexOf(u8, vm.diagnostics.items.items[0].message, "has run") != null);
}

test "an image imported by a module compiled from source is refused, with the reason" {
    const first = try Vm.create(gpa, .{});
    defer first.destroy();
    const shapes = try first.compile("shapes.flux", shapes_source);
    const saved = try first.saveCompiled(shapes, gpa, .{});
    defer gpa.free(saved);

    var files: Files = .{ .items = &.{.{ .name = "shapes.flux", .bytes = saved }} };
    const vm = try Vm.create(gpa, .{ .loader = files.loader() });
    defer vm.destroy();
    try testing.expectError(error.CompileFailed, vm.compile("game.flux", game_source));
    try testing.expect(std.mem.indexOf(u8, vm.diagnostics.items.items[0].message, "is compiled") != null);
}
