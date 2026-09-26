// SPDX-License-Identifier: BSD-2-Clause

//! The host's types in scripts: named in types and where values go, their
//! members known and offered, their calls checked, their enums Flux enums,
//! a union's arms told apart with `is`, the methods another type gives
//! them, and the methods the host calls - checked where they are compiled,
//! and working where they run.

const std = @import("std");
const testing = std.testing;

const reflect = @import("fluxion_reflect");
const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const bridge = @import("reflect.zig");
const service = @import("service.zig");
const Analysis = service.Analysis;

const Mode = enum { stop, play, loop };

/// A player of clips, as a host would give one.
const Deck = struct {
    name: [16]u8 = @splat(0),
    speed: f32 = 1,
    count: i32 = 0,
    mode: Mode = .stop,
    state: u8 = 0,
    pace: Pace = .slow,
    cut: Cut = .none,
    seat: Seat = .none,

    /// Named by a script only as `deck.pace` wants it: `Card` has a `Pace`
    /// too.
    pub const Pace = enum { slow, fast };
    pub const Cut = union(enum) { none, at: Split };
    pub const Split = struct { index: i32 = 0, side: Side = .top };
    pub const Side = enum { top, bottom };

    pub const reflect_fields = .{
        .speed = .{reflect.attr.Doc{ .text = "How fast it plays" }},
        .state = .{reflect.attr.Hidden{}},
    };
    pub const reflect_methods = .{
        .play = .{ reflect.attr.Params{ .names = &.{ "name", "speed", "from_end" } }, reflect.attr.defaults(.{ "", 1.0, false }), reflect.attr.Doc{ .text = "Plays a clip" } },
        .card = .{reflect.attr.Params{ .names = &.{"which"} }},
        .get = .{reflect.attr.Params{ .names = &.{ "vm", "kind" } }},
        .find = .{reflect.attr.Params{ .names = &.{ "vm", "kind" } }},
        .setMode = .{reflect.attr.Params{ .names = &.{"mode"} }},
        .load = .{reflect.attr.Params{ .names = &.{"path"} }},
        .seatOf = .{},
        .takeSeat = .{},
    };

    /// The seat it has, or none.
    pub fn seatOf(self: *const Deck) Seat {
        return self.seat;
    }

    /// A seat of its own, or it fails: never none.
    pub fn takeSeat(self: *Deck) error{Full}!Seat {
        if (self.count > 10) return error.Full;
        return .{ .number = 1 };
    }

    pub fn play(self: *Deck, name: []const u8, speed: f32, from_end: bool) void {
        _ = name;
        self.speed = if (from_end) -speed else speed;
    }

    pub fn card(self: *Deck, which: i32) Card {
        _ = self;
        return .{ .value = which };
    }

    /// A card, asked for by its type: a script's `deck.get(Card)`.
    pub fn get(self: *Deck, vm: *Vm, kind: *const reflect.Type) Vm.Error!Value {
        if (!kind.is(Card)) return vm.fail("a deck has no {s}", .{bridge.nameOf(kind)});
        const made = try vm.newHandle(Card);
        const held: *Card = @ptrCast(@alignCast(made.as(@import("vm/object.zig").Handle).value.ptr));
        held.* = .{ .value = self.count };
        return made;
    }

    pub fn find(self: *Deck, vm: *Vm, kind: *const reflect.Type) Vm.Error!?Value {
        if (self.count == 0) return null;
        return try self.get(vm, kind);
    }

    pub fn setMode(self: *Deck, mode: Mode) void {
        self.mode = mode;
    }

    /// Fails as a mistake would: its errors stop the script.
    pub fn load(self: *Deck, path: []const u8) error{NotFound}!void {
        _ = self;
        if (path.len == 0) return error.NotFound;
    }
};

const Card = struct {
    value: i32 = 0,
    side: Pace = .up,

    pub const Pace = enum { up, down };

    pub const reflect_attributes = .{bridge.GivesErrors{}};
    pub const reflect_methods = .{
        .flip = .{},
        .read = .{},
        .copy = .{ reflect.attr.Params{ .names = &.{"vm"} }, bridge.Returns.of(Card) },
    };

    pub fn flip(self: *Card) void {
        self.value = -self.value;
    }

    /// Fails as a file can: its errors are a script's to catch.
    pub fn read(self: *Card) error{Unreadable}![]const u8 {
        if (self.value < 0) return error.Unreadable;
        return "ace";
    }

    /// A card the collector owns, as a `flux.Value` whose type the method
    /// says.
    pub fn copy(self: *Card, vm: *Vm) Vm.Error!Value {
        const made = try vm.newHandle(Card);
        const held: *Card = @ptrCast(@alignCast(made.as(@import("vm/object.zig").Handle).value.ptr));
        held.* = self.*;
        return made;
    }
};

const KeyPress = struct { code: i32 = 0, pressed: bool = true };
const Move = struct { dx: f32 = 0, dy: f32 = 0 };

/// What the player did: a key, a move, or nothing.
const Input = union(enum) {
    key: KeyPress,
    move: Move,
    idle,

    pub const reflect_methods = .{.isKey};

    pub fn isKey(self: *const Input) bool {
        return self.* == .key;
    }
};

/// A seat at the table, which may be empty: none, to a script null.
const Seat = extern struct {
    number: u8 = 0,

    pub const none: Seat = .{};
};

fn seatToScript(_: *Vm, value: reflect.Value) Vm.Error!Value {
    const seat = value.get(Seat).?;
    return if (seat.number == 0) .null else .int(seat.number);
}

fn seatFromScript(vm: *Vm, into: reflect.Value, value: Value) Vm.Error!void {
    const seat: Seat = switch (value.tag) {
        .null => .none,
        .int => .{ .number = @intCast(value.asInt()) },
        else => return vm.fail("a seat is a number, or null for none", .{}),
    };
    into.set(Seat, seat) catch return vm.fail("this seat can only be read", .{});
}

const seat_type: Vm.HostType = .{ .type = reflect.typeOf(Seat), .given = .int, .nullable = true, .to_script = seatToScript, .from_script = seatFromScript };

/// What gives a deck the methods whose first argument is one.
const Table = struct {
    dealt: i32 = 0,

    pub const reflect_methods = .{
        .deal = .{ reflect.attr.Params{ .names = &.{ "deck", "cards" } }, bridge.Alias{ .name = "dealOut" } },
        .countOf = .{reflect.attr.Params{ .names = &.{"deck"} }},
        .sit = .{ reflect.attr.Params{ .names = &.{ "deck", "seat" } }, bridge.GivesErrors{} },
    };

    /// Takes a seat for the deck, or none; a taken one is refused as a
    /// value, as this method says.
    pub fn sit(self: *Table, deck: *Deck, seat: Seat) error{Taken}!void {
        _ = deck;
        if (seat.number == 13) return error.Taken;
        self.dealt += seat.number;
    }

    pub fn deal(self: *Table, deck: *Deck, cards: i32) void {
        self.dealt += cards;
        deck.count += cards;
    }

    pub fn countOf(self: *const Table, deck: *const Deck) i32 {
        _ = self;
        return deck.count;
    }
};

/// What the hooks are given: the host's, as long as the VM lives.
const tick_params = [_]Vm.Hook.Param{.{ .name = "dt", .type = reflect.typeOf(f32) }};
const input_params = [_]Vm.Hook.Param{.{ .name = "event", .type = reflect.typeOf(Input) }};

fn declare(vm: *Vm) !void {
    inline for (.{ Deck, Card, Mode, Input, KeyPress, Move }) |T| try vm.declareType(reflect.typeOf(T));
    try vm.declareHook(.{ .name = "tick", .params = &tick_params, .doc = "Called each frame." });
    try vm.declareHook(.{ .name = "input", .params = &input_params });
    try vm.declareAnnotation(.{ .name = "range", .sig = "@range(min, max)", .doc = "The numbers it may be." });
    try vm.declareMember(.{ .of = reflect.typeOf(Deck), .name = "emptied", .type = .signal, .doc = "Said when the last card goes." });
    try vm.declareMember(.{ .of = reflect.typeOf(Deck), .name = "title", .type = .string, .writable = true });
}

fn setup(_: ?*anyopaque, vm: *Vm) anyerror!void {
    try declare(vm);
    try vm.declareGlobal("deck", reflect.typeOf(Deck), "The deck on the table.");
    try vm.declareHostMemberOf("held", reflect.typeOf(Deck), "The deck this one holds.");
    try vm.extend(reflect.typeOf(Deck), reflect.typeOf(Table), .null);
    vm.options.host_types = &.{seat_type};
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

test "a call of a host's method is checked as it is compiled: its arguments, the last ones left out, and their types" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\fn ok() {
        \\    deck.play();
        \\    deck.play("walk");
        \\    deck.play("walk", 2);
        \\    deck.play("walk", 2.0, true);
        \\    print(deck.speed + 1.0, deck.count + 1, deck.name.len);
        \\    deck.card(3).flip();
        \\    var d = deck;
        \\    d.play("run");
        \\}
    , &.{});
    try expectMessages(a,
        \\fn wrong() {
        \\    deck.play("walk", 1.0, false, 4);
        \\    deck.play(3);
        \\    deck.card(1).flip(9);
        \\    deck.whatever(1);
        \\    var d = deck;
        \\    d = deck.card(2);
        \\}
    , &.{
        "`play` takes 0 to 3 arguments, and is given 4",
        "the argument must be string, not int",
        "`flip` takes 0 arguments, and is given 1",
        "`Deck` has no field or method `whatever`",
        "the variable must be Deck, not Card",
    });
    // A member the host gives every struct, of a type it said.
    try expectMessages(a,
        \\struct Player {
        \\    fn go(self) {
        \\        self.held.play("a", 1.0, false, true);
        \\    }
        \\}
    , &.{"`play` takes 0 to 3 arguments, and is given 4"});
}

test "the host's types are named in types and where values go" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\fn shuffle(d: Deck, times: int) Card {
        \\    const top: Card = d.card(times);
        \\    return top;
        \\}
        \\fn named() {
        \\    print(Deck, Mode.loop);
        \\    const c = shuffle(deck, 2);
        \\    c.flip();
        \\}
    , &.{});
    try expectMessages(a,
        \\fn wrong(d: Dekc) {
        \\    shuffle(deck.card(1));
        \\    print(Deck{});
        \\}
        \\fn shuffle(d: Deck) {}
    , &.{
        "`Dekc` is not a type",
        "the argument must be Deck, not Card",
        "a `Deck` is the host's to make, not a script's",
    });
}

test "a host's enum is a Flux enum: its members named with a dot where one is wanted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\fn ok() {
        \\    deck.setMode(.loop);
        \\    deck.mode = .play;
        \\    if (deck.mode == .stop) print("stopped");
        \\    const m: Mode = Mode.play;
        \\    print(m);
        \\}
    , &.{});
    try expectMessages(a,
        \\fn wrong() {
        \\    deck.setMode("loop");
        \\    if (deck.mode == .jump) print("?");
        \\    deck.mode = 1;
        \\}
    , &.{
        "the argument must be Mode, not string",
        "`Mode` has no member `jump`",
        "the field must be Mode, not int",
    });
}

test "a host's union is told apart with `is`, and what it is known to be is known after" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\fn read(e: Input) int {
        \\    if (e.isKey()) print("a key");
        \\    if (e is KeyPress) {
        \\        print(e.code, e.isKey());
        \\    } else if (e is Move) {
        \\        print(e.dx + e.dy);
        \\    }
        \\    if (e is KeyPress and e.pressed) print("down");
        \\    if (!(e is Move)) return 0;
        \\    return int(e.dx);
        \\}
    , &.{});
    try expectMessages(a,
        \\fn read(e: Input) {
        \\    print(e.code);
        \\    if (e is KeyPress) print(e.dx);
        \\    var loose = e;
        \\    if (loose is KeyPress) print(loose.code);
        \\}
    , &.{
        "`Input` has no field or method `code`",
        "`KeyPress` has no field or method `dx`",
        "`Input` has no field or method `code`",
    });
    // A union's arm that holds nothing, by its name.
    try expectMessages(a,
        \\fn idle() Input {
        \\    return .idle;
        \\}
        \\fn wrong() Input {
        \\    return .key;
        \\}
    , &.{"`Input.key` holds a KeyPress, which a name does not give"});
}

test "the choices a declared type's values take are named with it, but for a name two of them have" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\const cuts: [Cut] = [.none, .none];
        \\fn index(c: Cut) int {
        \\    if (c is Split and c.side == Side.top) return c.index;
        \\    return 0;
        \\}
        \\fn quick() {
        \\    deck.pace = .fast;
        \\    const cut: Cut = deck.cut;
        \\    print(cut == cuts[0]);
        \\}
    , &.{});
    try expectMessages(a, "var pace: Pace = .fast;", &.{ "`Pace` is not a type", "which enum is `.fast` a member of?" });
}

test "what may be none is optional to a script, but what a method that can fail gives" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\fn seats() int {
        \\    if (deck.seat == null or deck.seatOf() == null) return 0;
        \\    deck.seat = null;
        \\    return deck.takeSeat() + deck.seatOf().?;
        \\}
    , &.{});
    try expectMessages(a, "fn f() int { return deck.seatOf(); }", &.{"the return value must be int, but this may be null"});
}

test "a method given a type gives a value of it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\fn ok() {
        \\    deck.get(Card).flip();
        \\    if (deck.find(Card)) |c| c.flip();
        \\    deck.card(1).copy().flip();
        \\}
    , &.{});
    try expectMessages(a,
        \\fn wrong() {
        \\    deck.get(Card).shuffle();
        \\    deck.find(Card).flip();
        \\    deck.get(3);
        \\    deck.card(1).copy().shuffle();
        \\}
    , &.{
        "`Card` has no field or method `shuffle`",
        "cannot call `flip` on a value that may be null",
        "`kind` is a type, and is given int",
        "`Card` has no field or method `shuffle`",
    });
}

test "another type's methods are a value's own, under their aliases" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\fn ok() int {
        \\    deck.dealOut(3);
        \\    deck.sit(4) catch {};
        \\    deck.sit(null) catch |err| print(err);
        \\    return deck.countOf();
        \\}
    , &.{});
    try expectMessages(a,
        \\fn wrong() {
        \\    deck.dealOut();
        \\    deck.deal(1);
        \\    deck.sit(1);
        \\}
    , &.{
        "`dealOut` takes 1 argument, and is given 0",
        "`Deck` has no field or method `deal`",
        "the error this may give is ignored",
    });
}

test "members the host declares beside a type's, and the errors a script is given" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\fn ok() {
        \\    deck.emptied.connect(fn() { print("empty"); });
        \\    deck.title = "Solitaire";
        \\    deck.load("clubs.deck");
        \\    const text = deck.card(1).read() catch "none";
        \\    print(text.len);
        \\}
    , &.{});
    try expectMessages(a,
        \\fn wrong() {
        \\    deck.emptied = 3;
        \\    const _text: string = deck.card(1).read();
        \\}
    , &.{
        "`Deck.emptied` can only be read",
        "the variable must be string, but this may be an error",
    });
}

test "a method the host calls is checked, and its parameters typed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectMessages(a,
        \\struct Player {
        \\    @range(0, 10) var speed: float = 1.0;
        \\    fn tick(self, dt) {
        \\        self.speed += dt;
        \\    }
        \\    fn input(self, event: any) {
        \\        if (event is KeyPress) print(event.code);
        \\    }
        \\}
    , &.{});
    try expectMessages(a,
        \\struct Player {
        \\    @rnage(0, 10) var speed: float = 1.0;
        \\    fn tick(self) {}
        \\    fn input(self, event) {
        \\        print(event.code);
        \\    }
        \\}
    , &.{
        "`@rnage` is no annotation the host reads",
        "the host calls `tick` with 1 argument, and this takes 0",
        "`Input` has no field or method `code`",
    });
}

test "where the scripts run: enums, unions, types given, another type's methods and errors cross as they were compiled" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    try declare(vm);
    var deck: Deck = .{ .count = 2 };
    var table: Table = .{};
    try vm.defineGlobal("deck", try vm.handle(&deck), null);
    try vm.extend(reflect.typeOf(Deck), reflect.typeOf(Table), try vm.handle(&table));
    const m = try vm.load("run.flux",
        \\fn modes() Mode {
        \\    deck.setMode(.loop);
        \\    return deck.mode;
        \\}
        \\fn kind(e: Input) int {
        \\    if (e is KeyPress) return e.code;
        \\    if (e is Move) return int(e.dx);
        \\    return -1;
        \\}
        \\fn keyed(e: Input) bool {
        \\    return e.isKey();
        \\}
        \\fn idled(e: Input) bool {
        \\    return e == .idle;
        \\}
        \\const choices: [Input] = [.idle, .idle];
        \\fn chosen(e: Input) bool {
        \\    return e == choices[0] and !(e is KeyPress);
        \\}
        \\fn given() int {
        \\    const c = deck.get(Card);
        \\    c.flip();
        \\    return c.value;
        \\}
        \\fn dealt() int {
        \\    deck.dealOut(3);
        \\    return deck.countOf();
        \\}
        \\fn caught() string {
        \\    const c = deck.card(-1);
        \\    return c.read() catch |err| err.name;
        \\}
        \\fn stopped() {
        \\    deck.load("");
        \\}
    );
    const mode = try vm.callName(m, "modes", &.{});
    try testing.expectEqual(Mode.loop, deck.mode);
    try testing.expectEqualStrings("Mode", @import("vm/types.zig").typeName(mode));

    var key: Input = .{ .key = .{ .code = 42 } };
    var move: Input = .{ .move = .{ .dx = 7 } };
    var idle: Input = .idle;
    try testing.expectEqual(@as(i64, 42), (try vm.callName(m, "kind", &.{try vm.valueOf(.of(&key))})).asInt());
    try testing.expectEqual(@as(i64, 7), (try vm.callName(m, "kind", &.{try vm.valueOf(.of(&move))})).asInt());
    try testing.expectEqual(@as(i64, -1), (try vm.callName(m, "kind", &.{try vm.valueOf(.of(&idle))})).asInt());
    try testing.expect((try vm.callName(m, "keyed", &.{try vm.valueOf(.of(&key))})).asBool());
    try testing.expect((try vm.callName(m, "idled", &.{try vm.valueOf(.of(&idle))})).asBool());
    try testing.expect(!(try vm.callName(m, "idled", &.{try vm.valueOf(.of(&key))})).asBool());
    try testing.expect((try vm.callName(m, "chosen", &.{try vm.valueOf(.of(&idle))})).asBool());

    try testing.expectEqual(@as(i64, -2), (try vm.callName(m, "given", &.{})).asInt());
    try testing.expectEqual(@as(i64, 5), (try vm.callName(m, "dealt", &.{})).asInt());
    try testing.expectEqual(@as(i32, 3), table.dealt);
    const err = try vm.callName(m, "caught", &.{});
    try testing.expectEqualStrings("Unreadable", err.as(@import("vm/object.zig").String).bytes());
    try testing.expectError(error.Panic, vm.callName(m, "stopped", &.{}));
    try testing.expect(std.mem.indexOf(u8, vm.panic.?.message, "`load` failed: error.NotFound") != null);
    vm.clearPanic();
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
    try testing.expectEqualStrings("Deck.mode: Mode", itemNamed(items, "mode").?.detail);
    try testing.expectEqualStrings("fn Deck.get(kind: type) any", itemNamed(items, "get").?.detail);
    try testing.expectEqualStrings("fn Deck.dealOut(cards: int)", itemNamed(items, "dealOut").?.detail);
    try testing.expectEqualStrings("Said when the last card goes.", itemNamed(items, "emptied").?.doc.?);
    try testing.expect(itemNamed(items, "name") != null);
    try testing.expect(itemNamed(items, "state") == null);
    try testing.expect(itemNamed(items, "deal") == null);
    // Through a call, a type given, and a union's arm.
    try testing.expect(itemNamed(try completions(a, "fn f() {\n    deck.card(1).$\n}\n"), "flip") != null);
    try testing.expect(itemNamed(try completions(a, "fn f() {\n    deck.get(Card).$\n}\n"), "flip") != null);
    try testing.expect(itemNamed(try completions(a, "struct P {\n    fn go(self) {\n        self.held.$\n    }\n}\n"), "play") != null);
    const arm = try completions(a, "fn f(e: Input) {\n    if (e is KeyPress) {\n        e.$\n    }\n}\n");
    try testing.expect(itemNamed(arm, "code") != null);
    try testing.expect(itemNamed(arm, "isKey") != null);
    // Where a member of the enum is wanted.
    try testing.expect(itemNamed(try completions(a, "fn f() {\n    deck.setMode(.$\n}\n"), "loop") != null);
    // Where a type is written.
    try testing.expect(itemNamed(try completions(a, "fn f(d: $) {}\n"), "Deck") != null);

    // A method the host calls, whole, where a struct's method is written;
    // those written already are not offered again.
    const after_fn = try completions(a, "struct P {\n    fn tick(self, dt: float) {}\n    fn inp$\n}\n");
    try testing.expect(itemNamed(after_fn, "tick") == null);
    const input = itemNamed(after_fn, "input") orelse return error.NotOffered;
    try testing.expectEqualStrings("fn input(self, event: Input) {\n        \n    }", input.insert.?);
    try testing.expectEqualStrings("fn input(self, event: Input) {\n        ", input.insert.?[0..input.caret.?]);
    const member = try completions(a, "struct P {\n    var x = 1;\n    ti$\n}\n");
    try testing.expect(itemNamed(member, "tick") != null);
    try testing.expect(itemNamed(member, "var") != null);
    // Not in a function's body.
    try testing.expect(itemNamed(try completions(a, "struct P {\n    fn go(self) {\n        ti$\n    }\n}\n"), "tick") == null);
    // After a `@`, the annotations: the language's and the host's.
    const at = try completions(a, "struct P {\n    @$\n    var x = 1;\n}\n");
    try testing.expect(itemNamed(at, "export") != null);
    try testing.expectEqualStrings("The numbers it may be.", itemNamed(at, "range").?.doc.?);
    try testing.expect(itemNamed(try completions(a, "struct P {\n    @ra$\n    var x = 1;\n}\n"), "range") != null);

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
