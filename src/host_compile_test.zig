// SPDX-License-Identifier: BSD-2-Clause

//! What the compiler and the language service know of the host's values:
//! calls of their methods checked, their members offered, their signatures
//! and docs shown.

const std = @import("std");
const testing = std.testing;

const reflect = @import("fluxion_reflect");
const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const service = @import("service.zig");
const Analysis = service.Analysis;

/// A player of clips, as a host would give one.
const Deck = struct {
    name: [16]u8 = @splat(0),
    speed: f32 = 1,
    count: i32 = 0,
    state: u8 = 0,

    pub const reflect_fields = .{
        .speed = .{reflect.attr.Doc{ .text = "How fast it plays" }},
        .state = .{reflect.attr.Hidden{}},
    };
    pub const reflect_methods = .{
        .play = .{ reflect.attr.Params{ .names = &.{ "name", "speed", "from_end" } }, reflect.attr.defaults(.{ "", 1.0, false }), reflect.attr.Doc{ .text = "Plays a clip" } },
        .card = .{reflect.attr.Params{ .names = &.{"which"} }},
        .find = .{reflect.attr.Params{ .names = &.{ "vm", "what" } }},
    };

    pub fn play(self: *Deck, name: []const u8, speed: f32, from_end: bool) void {
        _ = name;
        self.speed = if (from_end) -speed else speed;
    }

    pub fn card(self: *Deck, which: i32) Card {
        _ = self;
        return .{ .value = which };
    }

    /// A value only the host knows the kind of: what `host_result` says.
    pub fn find(self: *Deck, vm: *Vm, what: []const u8) Value {
        _ = self;
        _ = vm;
        _ = what;
        return .null;
    }
};

const Card = struct {
    value: i32 = 0,

    pub const reflect_methods = .{.flip};

    pub fn flip(self: *Card) void {
        self.value = -self.value;
    }
};

/// `find("deck")` is a deck.
fn findsDecks(_: ?*anyopaque, receiver: *const reflect.Type, method: []const u8, strings: []const ?[]const u8) ?*const reflect.Type {
    if (!receiver.is(Deck) or !std.mem.eql(u8, method, "find")) return null;
    if (strings.len == 0) return null;
    const what = strings[0] orelse return null;
    return if (std.mem.eql(u8, what, "deck")) reflect.typeOf(Deck) else null;
}

fn setup(_: ?*anyopaque, vm: *Vm) anyerror!void {
    try vm.declareGlobal("deck", reflect.typeOf(Deck), "The deck on the table.");
    try vm.declareHostMemberOf("held", reflect.typeOf(Deck), "The deck this one holds.");
    vm.options.host_result = .{ .run = findsDecks };
}

const options: service.Options = .{ .setup = .{ .run = setup } };

fn messages(arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const a = try Analysis.init(testing.allocator, "deck.flux", source, options);
    defer a.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    for (a.diagnostics.items.items) |d| try out.append(arena, try arena.dupe(u8, d.message));
    return out.items;
}

fn expectMessages(arena: std.mem.Allocator, source: []const u8, want: []const []const u8) !void {
    const got = try messages(arena, source);
    testing.expectEqual(want.len, got.len) catch |err| {
        for (got) |m| std.debug.print("  {s}\n", .{m});
        return err;
    };
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "a call of a host's method is checked as it is compiled: its arguments, the last ones left out, and what each is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // What is right compiles; what its type does not list is still the
    // host's to have.
    try expectMessages(a,
        \\fn ok() {
        \\    deck.play();
        \\    deck.play("walk");
        \\    deck.play("walk", 2);
        \\    deck.play("walk", 2.0, true);
        \\    print(deck.speed + 1.0, deck.count + 1, deck.name.len);
        \\    deck.whatever(1, 2, 3);
        \\    deck.card(3).flip();
        \\}
    , &.{});
    try expectMessages(a,
        \\fn wrong() {
        \\    deck.play("walk", 1.0, false, 4);
        \\    deck.play(3);
        \\    deck.card(1).flip(9);
        \\    const found = deck.find("deck");
        \\    found.play("a", 1.0, false, 4);
        \\}
    , &.{
        "`play` takes 0 to 3 arguments, and is given 4",
        "`name` is string, and is given int",
        "`flip` takes 0 arguments, and is given 1",
        "`play` takes 0 to 3 arguments, and is given 4",
    });
    // A variable may be given another value: its calls are not checked.
    // Nor is what the host cannot say the kind of.
    try expectMessages(a,
        \\fn loose() {
        \\    var d = deck;
        \\    d.play(1, 2, 3, 4, 5);
        \\    deck.find("card").play(1, 2, 3, 4, 5);
        \\}
    , &.{});
    // A member the host gives every struct, of a type it said.
    try expectMessages(a,
        \\struct Player {
        \\    fn go(self) {
        \\        self.held.play("a", 1.0, false, true);
        \\    }
        \\}
    , &.{"`play` takes 0 to 3 arguments, and is given 4"});
}

test "a global the host defined is known by its handle's type where the scripts run" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    var deck: Deck = .{};
    const h = try vm.handle(&deck);
    try vm.defineGlobal("deck", h, null);
    try testing.expectError(error.CompileFailed, vm.load("wrong.flux", "fn f() { deck.play(1, 2, 3, 4); }"));
    try vm.writeDiagnostics(&out.writer, .{});
    try testing.expect(std.mem.indexOf(u8, out.written(), "`play` takes 0 to 3 arguments, and is given 4") != null);
    const m = try vm.load("right.flux", "fn f() { deck.play(\"a\", 3); return deck.speed; }");
    try testing.expectEqual(@as(f64, 3), (try vm.callName(m, "f", &.{})).asFloat());
}

fn completions(arena: std.mem.Allocator, source: []const u8) ![]const @import("service/complete.zig").Item {
    const cursor = std.mem.indexOfScalar(u8, source, '$').?;
    const text = try std.fmt.allocPrint(arena, "{s}{s}", .{ source[0..cursor], source[cursor + 1 ..] });
    return (try service.complete(testing.allocator, arena, "deck.flux", text, @intCast(cursor), options)).items;
}

fn itemNamed(items: []const @import("service/complete.zig").Item, name: []const u8) ?@import("service/complete.zig").Item {
    for (items) |i| if (std.mem.eql(u8, i.label, name)) return i;
    return null;
}

test "an editor is offered a host's members, and shown its methods' signatures and docs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = try completions(a, "fn f() {\n    deck.$\n}\n");
    const play = itemNamed(items, "play") orelse return error.NotOffered;
    try testing.expectEqualStrings("fn Deck.play(name: string = \"\", speed: float = 1.0, from_end: bool = false)", play.detail);
    try testing.expectEqualStrings("Plays a clip", play.doc.?);
    try testing.expectEqualStrings("Deck.speed: float", itemNamed(items, "speed").?.detail);
    try testing.expect(itemNamed(items, "card") != null);
    try testing.expect(itemNamed(items, "name") != null);
    try testing.expect(itemNamed(items, "state") == null);
    // Through a call, and through what the host says a call gives.
    try testing.expect(itemNamed(try completions(a, "fn f() {\n    deck.card(1).$\n}\n"), "flip") != null);
    try testing.expect(itemNamed(try completions(a, "fn f() {\n    const d = deck.find(\"deck\");\n    d.$\n}\n"), "play") != null);
    try testing.expect(itemNamed(try completions(a, "struct P {\n    fn go(self) {\n        self.held.$\n    }\n}\n"), "play") != null);

    const source = "fn f() {\n    deck.play(\"a\", $\n}\n";
    const cursor = std.mem.indexOfScalar(u8, source, '$').?;
    const text = try std.fmt.allocPrint(a, "{s}{s}", .{ source[0..cursor], source[cursor + 1 ..] });
    const sig = (try service.signatureHelp(testing.allocator, a, "deck.flux", text, @intCast(cursor), options)).?;
    try testing.expectEqualStrings("Deck.play(name: string = \"\", speed: float = 1.0, from_end: bool = false)", sig.label);
    try testing.expectEqual(@as(u32, 1), sig.active);
    try testing.expectEqualStrings("Plays a clip", sig.doc.?);

    const program = "fn f() {\n    deck.play(\"a\");\n    print(deck.speed);\n}\n";
    const analysis = try Analysis.init(testing.allocator, "deck.flux", program, options);
    defer analysis.deinit();
    const on_play = (try analysis.hover(a, @intCast(std.mem.indexOf(u8, program, "play").? + 1))).?;
    try testing.expectEqualStrings("fn Deck.play(name: string = \"\", speed: float = 1.0, from_end: bool = false)", on_play.code);
    const on_speed = (try analysis.hover(a, @intCast(std.mem.indexOf(u8, program, "speed").? + 1))).?;
    try testing.expectEqualStrings("Deck.speed: float", on_speed.code);
    try testing.expectEqualStrings("How fast it plays", on_speed.doc.?);
}
