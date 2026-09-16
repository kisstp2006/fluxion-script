// SPDX-License-Identifier: BSD-2-Clause

//! The language service on a small program, as an editor would ask it.

const std = @import("std");
const testing = std.testing;

const service = @import("service.zig");
const Analysis = service.Analysis;

const program =
    \\const math = @import("math");
    \\
    \\/// Someone in the arena.
    \\struct Actor {
    \\    /// What is left of them.
    \\    var hp: int = 100;
    \\    var name: string = "nobody";
    \\    signal died(by: string);
    \\
    \\    /// Takes `amount` off, and says whether they still stand.
    \\    fn hit(self, amount: int) bool {
    \\        self.hp -= amount;
    \\        if (self.hp <= 0) self.died.emit("a hit");
    \\        return self.hp > 0;
    \\    }
    \\
    \\    fn make(name: string) Actor {
    \\        return Actor{ .name = name };
    \\    }
    \\}
    \\
    \\enum Mood { calm, angry }
    \\
    \\var mood: Mood = .calm;
    \\
    \\fn fight(a: Actor, rounds: int) {
    \\    for (0..rounds) |i| {
    \\        _ = a.hit(i * 2);
    \\    }
    \\    const left = a.hp;
    \\    print(left, math.sqrt(2.0));
    \\}
    \\
;

/// Where `needle` is in the program, plus `past` bytes.
fn at(needle: []const u8, past: usize) u32 {
    return @intCast(std.mem.indexOf(u8, program, needle).? + past);
}

fn analyze() !*Analysis {
    return Analysis.init(testing.allocator, "arena.flux", program, .{});
}

test "the program compiles cleanly for the service" {
    const a = try analyze();
    defer a.deinit();
    for (a.diagnostics.items.items) |d| std.debug.print("{s}\n", .{d.message});
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.items.len);
}

test "a hover says what a name is" {
    const a = try analyze();
    defer a.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Case = struct { []const u8, usize, []const u8, ?[]const u8 };
    const cases = [_]Case{
        .{ "a.hit(", 3, "fn Actor.hit(self, amount: int) bool", "Takes `amount` off" },
        .{ "a.hp;", 2, "var Actor.hp: int = 100", "What is left of them." },
        .{ "left, math", 1, "const left: int", null },
        .{ "0..rounds", 4, "rounds: int", null },
        .{ "print(left", 2, "fn print(values: any...)", "Writes the values" },
        .{ "sqrt(2.0)", 1, "fn math.sqrt(x: float) float", "The square root." },
        .{ "died.emit", 1, "signal Actor.died(by: string)", null },
        .{ "died.emit", 6, "fn signal.emit(values: any...)", "Calls what is connected" },
        .{ "Mood = .calm", 9, "Mood.calm = 0", null },
        .{ "var mood", 5, "var mood: Mood = .calm", null },
        .{ "hp: int", 5, "type int", "A whole number" },
    };
    for (cases) |case| {
        const h = (try a.hover(arena.allocator(), at(case[0], case[1]))) orelse {
            std.debug.print("no hover at `{s}`\n", .{case[0]});
            return error.NoHover;
        };
        testing.expectEqualStrings(case[2], h.code) catch |e| {
            std.debug.print("at `{s}`\n", .{case[0]});
            return e;
        };
        if (case[3]) |doc| try testing.expect(std.mem.startsWith(u8, h.doc.?, doc));
    }
}

test "a name leads to its declaration, and to its other uses" {
    const a = try analyze();
    defer a.deinit();
    const decl = a.definition(at("a.hit(", 3)).?;
    try testing.expectEqual(at("fn hit", 3), decl.span.start);
    try testing.expectEqual(a.file, decl.file);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const uses = try a.references(arena.allocator(), at("var hp", 4));
    // The declaration, three in `hit`, and one in `fight`.
    try testing.expectEqual(@as(usize, 5), uses.len);
    const left = try a.references(arena.allocator(), at("const left", 6));
    try testing.expectEqual(@as(usize, 2), left.len);
}

test "the outline has each declaration, members under their type" {
    const a = try analyze();
    defer a.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const symbols = try a.symbols(arena.allocator());
    var names: std.ArrayList(u8) = .empty;
    for (symbols) |s| {
        try names.print(arena.allocator(), "{s}:{s}", .{ s.name, @tagName(s.kind) });
        if (s.children.len > 0) {
            try names.appendSlice(arena.allocator(), "(");
            for (s.children, 0..) |ch, i| try names.print(arena.allocator(), "{s}{s}", .{ if (i > 0) " " else "", ch.name });
            try names.appendSlice(arena.allocator(), ")");
        }
        try names.appendSlice(arena.allocator(), " ");
    }
    try testing.expectEqualStrings("math:module Actor:struct(hp name died hit make) Mood:enum(calm angry) mood:variable fight:function ", names.items);
}

test "names are coloured by what they name" {
    const a = try analyze();
    defer a.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tokens = try service.highlight.tokens(a, arena.allocator());
    const Case = struct { []const u8, usize, service.TokenType };
    const cases = [_]Case{
        .{ ") Actor {", 2, .@"struct" },
        .{ "died.emit", 0, .event },
        .{ "amount;", 0, .parameter },
        .{ "/// Someone", 0, .comment },
        .{ "\"nobody\"", 0, .string },
        .{ "fn fight", 0, .keyword },
        .{ "fight(a", 0, .function },
        .{ "math.sqrt", 0, .namespace },
        .{ "emit(", 0, .method },
        .{ ".calm;", 1, .enum_member },
        .{ "100", 0, .number },
    };
    for (cases) |case| {
        const offset = at(case[0], case[1]);
        const found = for (tokens) |t| {
            if (t.start == offset) break t;
        } else {
            std.debug.print("no token at `{s}`\n", .{case[0]});
            return error.NoToken;
        };
        testing.expectEqual(case[2], found.type) catch |e| {
            std.debug.print("at `{s}`\n", .{case[0]});
            return e;
        };
    }
    // In order, and none overlapping the next.
    for (tokens[1..], tokens[0 .. tokens.len - 1]) |t, prev| try testing.expect(t.start >= prev.start + prev.len);
}

/// Completions at `$` in `source`, the program followed by it.
fn completions(arena: std.mem.Allocator, extra: []const u8) !service.Completions {
    const cursor = std.mem.indexOfScalar(u8, extra, '$').?;
    const source = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ program, extra[0..cursor], extra[cursor + 1 ..] });
    return service.complete(testing.allocator, arena, "arena.flux", source, @intCast(program.len + cursor), .{});
}

fn labels(arena: std.mem.Allocator, c: service.Completions) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (c.items) |i| try out.print(arena, "{s} ", .{i.label});
    return out.items;
}

fn expectOffered(arena: std.mem.Allocator, extra: []const u8, want: []const []const u8, not: []const []const u8) !void {
    const c = try completions(arena, extra);
    const all = try labels(arena, c);
    for (want) |w| {
        const found = for (c.items) |i| {
            if (std.mem.eql(u8, i.label, w)) break true;
        } else false;
        if (!found) {
            std.debug.print("`{s}` not offered in `{s}`: {s}\n", .{ w, extra, all });
            return error.NotOffered;
        }
    }
    for (not) |n| for (c.items) |i| if (std.mem.eql(u8, i.label, n)) {
        std.debug.print("`{s}` offered in `{s}`\n", .{ n, extra });
        return error.Offered;
    };
}

test "completions after a dot are the members of what is before it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectOffered(a, "fn f(x: Actor) {\n    x.$\n}\n", &.{ "hp", "name", "died", "hit" }, &.{ "make", "fight" });
    try expectOffered(a, "fn f(x: Actor) {\n    x.h$\n}\n", &.{ "hp", "hit" }, &.{});
    try expectOffered(a, "fn f(x: Actor) {\n    print(x.$)\n}\n", &.{ "hp", "hit" }, &.{});
    try expectOffered(a, "fn f() {\n    const x = Actor.$\n}\n", &.{ "make", "hit" }, &.{"hp"});
    try expectOffered(a, "fn f() {\n    mood = .$\n}\n", &.{ "calm", "angry" }, &.{"hp"});
    try expectOffered(a, "fn f() {\n    const x = Actor{ .$ }\n}\n", &.{ "hp", "name" }, &.{"died"});
    try expectOffered(a, "fn f() {\n    var xs = [1, 2];\n    xs.$\n}\n", &.{ "push", "pop", "len", "sort_by" }, &.{"angle"});
    try expectOffered(a, "fn f() {\n    const v = vec2(1, 2);\n    v.$\n}\n", &.{ "x", "y", "angle", "normalized" }, &.{"z"});
    try expectOffered(a, "fn f() {\n    math.$\n}\n", &.{ "sqrt", "pi", "random_int" }, &.{});
    try expectOffered(a, "fn f(x: Actor) {\n    print(f\"{x.$}\");\n}\n", &.{"hp"}, &.{});
    try expectOffered(a, "fn f(x: ?Actor) {\n    x.?.$\n}\n", &.{"hp"}, &.{});
}

test "completions of a name are what is in scope there" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try completions(a, "fn f(count: int) {\n    const late = 1;\n    {\n        var inner = 2;\n    }\n    co$\n    var after = 3;\n}\n");
    const rank = struct {
        fn of(list: service.Completions, name: []const u8) ?u8 {
            for (list.items) |i| if (std.mem.eql(u8, i.label, name)) return i.rank;
            return null;
        }
    }.of;
    try testing.expectEqual(@as(?u8, 0), rank(c, "count"));
    try testing.expectEqual(@as(?u8, 0), rank(c, "late"));
    try testing.expectEqual(@as(?u8, 1), rank(c, "fight"));
    try testing.expectEqual(@as(?u8, 1), rank(c, "Actor"));
    try testing.expectEqual(@as(?u8, 2), rank(c, "print"));
    try testing.expectEqual(@as(?u8, 3), rank(c, "return"));
    try testing.expectEqual(@as(?u8, null), rank(c, "inner"));
    try testing.expectEqual(@as(?u8, null), rank(c, "after"));

    try expectOffered(a, "var t: Mo$\n", &.{ "Mood", "Actor", "int", "vec2" }, &.{"fight"});
    try expectOffered(a, "fn g() {\n    for (0..3) |k| {\n        print(k$)\n    }\n}\n", &.{"k"}, &.{});
    try expectOffered(a, "@ex$", &.{ "export", "import" }, &.{});
    // Nothing is offered in a comment, or for a name being declared.
    try testing.expectEqual(@as(usize, 0), (try completions(a, "// fi$\n")).items.len);
    try testing.expectEqual(@as(usize, 0), (try completions(a, "var ne$\n")).items.len);
}

test "code that does not parse still gets what the file declares" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectOffered(arena.allocator(), "fn broken( {\n    fi$\n", &.{ "fight", "Actor", "print", "while" }, &.{});
}

fn signature(arena: std.mem.Allocator, extra: []const u8) !?service.Signature {
    const cursor = std.mem.indexOfScalar(u8, extra, '$').?;
    const source = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ program, extra[0..cursor], extra[cursor + 1 ..] });
    return service.signatureHelp(testing.allocator, arena, "arena.flux", source, @intCast(program.len + cursor), .{});
}

test "signature help shows the call's parameters, the current one marked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, []const u8, u32 };
    const cases = [_]Case{
        .{ "fn f(x: Actor) {\n    x.hit($\n}\n", "Actor.hit(amount: int) bool", 0 },
        .{ "fn f() {\n    const x = Actor.make($)\n}\n", "Actor.make(name: string) Actor", 0 },
        .{ "fn f() {\n    fight(Actor.make(\"a\"), $)\n}\n", "fight(a: Actor, rounds: int)", 1 },
        .{ "fn f() {\n    var xs = [1];\n    xs.push($)\n}\n", "push(value: int)", 0 },
        .{ "fn f() {\n    print(1, 2, $)\n}\n", "print(values: any...)", 0 },
        .{ "fn f() {\n    const p = math.pow(2.0, $\n}\n", "pow(base: float, exponent: float) float", 1 },
    };
    for (cases) |case| {
        const s = (try signature(a, case[0])) orelse {
            std.debug.print("no signature in `{s}`\n", .{case[0]});
            return error.NoSignature;
        };
        testing.expectEqualStrings(case[1], s.label) catch |e| {
            std.debug.print("in `{s}`\n", .{case[0]});
            return e;
        };
        try testing.expectEqual(case[2], s.active);
    }
    try testing.expect((try signature(a, "fn f() {\n    if ($\n}\n")) == null);
}

const enemies_source =
    \\/// Something to fight.
    \\struct Enemy {
    \\    var hp: int = 3;
    \\}
    \\
    \\/// Makes an enemy called `name`.
    \\fn spawn(name: string) Enemy {
    \\    return Enemy{};
    \\}
    \\
;

fn fromMemory(_: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, path: []const u8) anyerror!@import("vm/Vm.zig").Loader.Loaded {
    if (!std.mem.eql(u8, path, "enemies.flux")) return error.FileNotFound;
    return .{ .name = try gpa.dupe(u8, "enemies.flux"), .source = try gpa.dupe(u8, enemies_source) };
}

test "an import is followed: its declarations, their docs, their members" {
    const main_source =
        \\const enemies = @import("enemies.flux");
        \\fn f() {
        \\    const e = enemies.spawn("orc");
        \\    print(e.hp);
        \\}
        \\
    ;
    const options: service.Options = .{ .loader = .{ .load = fromMemory } };
    const a = try Analysis.init(testing.allocator, "main.flux", main_source, options);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.diagnostics.items.items.len);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const spawn: u32 = @intCast(std.mem.indexOf(u8, main_source, "spawn").? + 1);
    const h = (try a.hover(arena.allocator(), spawn)).?;
    try testing.expectEqualStrings("fn spawn(name: string) Enemy", h.code);
    try testing.expectEqualStrings("Makes an enemy called `name`.", h.doc.?);
    const decl = a.definition(spawn).?;
    try testing.expectEqualStrings("enemies.flux", a.fileName(decl.file));
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, enemies_source, "spawn(").?)), decl.span.start);
    const hp = (try a.hover(arena.allocator(), @intCast(std.mem.indexOf(u8, main_source, "hp").?))).?;
    try testing.expectEqualStrings("var Enemy.hp: int = 3", hp.code);

    const typed = "const enemies = @import(\"enemies.flux\");\nfn f() {\n    enemies.\n}\n";
    const c = try service.complete(testing.allocator, arena.allocator(), "main.flux", typed, @intCast(std.mem.indexOf(u8, typed, "enemies.\n").? + 8), options);
    try testing.expectEqualStrings("Enemy spawn ", try labels(arena.allocator(), c));
}

test "a file with mistakes is still analysed, its mistakes kept" {
    const source = "fn f() int {\n    return \"text\";\n}\nfn g() {\n    f().x;\n}\n";
    const a = try Analysis.init(testing.allocator, "bad.flux", source, .{});
    defer a.deinit();
    try testing.expect(a.diagnostics.errors >= 1);
    try testing.expect(a.isHere(&a.diagnostics.items.items[0]));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const h = (try a.hover(arena.allocator(), @intCast(std.mem.indexOf(u8, source, "f().x").?))).?;
    try testing.expectEqualStrings("fn f() int", h.code);
}

