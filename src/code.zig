// SPDX-License-Identifier: BSD-2-Clause

//! Flux in fluxion-code's editor: the language's words and rules, and its
//! language service behind them - colours by what each name is, mistakes as
//! they are made, the outline, completions, signatures, hovers and going to
//! a declaration.
//!
//! A module of its own, `fluxion_script_code`, so that a program using the
//! language never builds it: `zig build` makes it only when this package is
//! built itself, or when a dependant asks for `.code = true`. A program that
//! has fluxion-code already builds this file over its own instead, so the
//! two are one package.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flux = @import("fluxion_script");
const code = @import("fluxion_code");

const service = flux.service;

/// Flux, with what the service's analyses are given - the host's natives,
/// its modules, what its strings may be - behind it. Keep one where it will
/// not move: the language it makes points at it.
pub const Flux = struct {
    options: service.Options = .{},

    pub fn language(self: *Flux) code.Language {
        return .{
            .name = "Flux",
            .line_comment = "//",
            .pairs = &.{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' }, .{ '"', '"' } },
            .indent = .{ .spaces = 4 },
            .indent_after = "{([",
            // What colours it while the service has not said: a file that
            // does not read at all.
            .lexis = .{ .keywords = flux.syntax.token.keywords.keys(), .quotes = "\"", .numbers = true },
            .colors = &color_forms,
            .service = .{
                .context = self,
                .analyze = analyze,
                .forget = forget,
                .complete = complete,
                .signature = signature,
                .hover = hover,
                .definition = definition,
                // A member after `.`, a builtin after `@`, and what a host
                // offers inside the quotes of a call it knows.
                .triggers = ".@\"",
            },
        };
    }

    fn of(context: ?*anyopaque) *Flux {
        return @ptrCast(@alignCast(context.?));
    }
};

/// How Flux writes a colour: `color(r, g, b[, a])`, `color("#RRGGBB")`,
/// `hsv(h, s, v[, a])` and `color("name")`, which the editor puts a swatch
/// and a picker before.
const color_forms = [_]code.colors.Form{
    .{ .channels = .{ .call = "color" } },
    .{ .hex = .{ .call = "color" } },
    .{ .hsv = .{ .call = "hsv" } },
    .{ .named = .{ .call = "color", .names = &color_names } },
};

const color_names = names: {
    var out: [flux.color_names.names.len]code.colors.Name = undefined;
    for (flux.color_names.names, &out) |n, *o| o.* = .{ .name = n.name, .rgb = n.rgb };
    break :names out;
};

fn analysisOf(state: ?*anyopaque) ?*service.Analysis {
    return @ptrCast(@alignCast(state orelse return null));
}

fn analyze(context: ?*anyopaque, gpa: Allocator, arena: Allocator, path: []const u8, text: []const u8) code.Error!code.Analysis {
    const a = service.Analysis.init(gpa, path, text, Flux.of(context).options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // What the host gives its scripts could not be given: the lexis
        // colours it, and nothing is said of it.
        else => return .{},
    };
    errdefer a.deinit();

    const said = try service.highlight.tokens(a, arena);
    const tokens = try arena.alloc(code.Token, said.len);
    for (said, tokens) |t, *out| out.* = .{ .start = t.start, .len = t.len, .style = styleOf(t.type, t.modifiers) };

    var problems: std.ArrayList(code.Problem) = .empty;
    for (a.diagnostics.items.items) |*d| {
        if (!a.isHere(d)) continue;
        const at = d.primary() orelse continue;
        const message = if (d.help) |h| try std.fmt.allocPrint(arena, "{s} - {s}", .{ d.message, h }) else d.message;
        try problems.append(arena, .{
            .start = at.span.start,
            .end = at.span.end,
            .severity = switch (d.severity) {
                .@"error" => .@"error",
                .warning => .warning,
                .note => .note,
            },
            .message = message,
        });
    }
    return .{
        .state = a,
        .tokens = tokens,
        .problems = problems.items,
        .symbols = try symbolsOf(arena, try a.symbols(arena)),
    };
}

fn forget(_: ?*anyopaque, state: *anyopaque) void {
    analysisOf(state).?.deinit();
}

fn symbolsOf(arena: Allocator, symbols: []const service.Symbol) Allocator.Error![]const code.Symbol {
    const out = try arena.alloc(code.Symbol, symbols.len);
    for (symbols, out) |s, *o| o.* = .{
        .name = s.name,
        .kind = kindOf(s.kind),
        .detail = s.detail,
        .start = s.span.start,
        .end = s.span.end,
        .children = try symbolsOf(arena, s.children),
    };
    return out;
}

fn complete(context: ?*anyopaque, gpa: Allocator, arena: Allocator, path: []const u8, text: []const u8, offset: u32) code.Error!?code.Completions {
    const found = service.complete(gpa, arena, path, text, offset, Flux.of(context).options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const items = try arena.alloc(code.Item, found.items.len);
    for (found.items, items) |item, *out| {
        const callable = switch (item.kind) {
            .function, .method, .builtin_function, .builtin_method => true,
            else => false,
        };
        out.* = .{
            .label = item.label,
            .kind = kindOf(item.kind),
            .detail = item.detail,
            .doc = item.doc,
            .rank = item.rank,
            .call = if (!callable) .none else if (std.mem.indexOf(u8, item.detail, "()") != null) .empty else .arguments,
            .swatch = if (item.color) |rgb| .{
                @as(f32, @floatFromInt(rgb >> 16)) / 255,
                @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255,
                @as(f32, @floatFromInt(rgb & 0xFF)) / 255,
                1,
            } else null,
        };
    }
    return .{ .items = items, .start = found.start, .end = found.end };
}

fn signature(context: ?*anyopaque, gpa: Allocator, arena: Allocator, path: []const u8, text: []const u8, offset: u32) code.Error!?code.Signature {
    const found = (service.signatureHelp(gpa, arena, path, text, offset, Flux.of(context).options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    }) orelse return null;
    return .{ .label = found.label, .params = found.params, .active = found.active, .doc = found.doc };
}

fn hover(_: ?*anyopaque, state: ?*anyopaque, arena: Allocator, _: []const u8, offset: u32) code.Error!?code.Hover {
    const a = analysisOf(state) orelse return null;
    const found = (try a.hover(arena, offset)) orelse return null;
    // The analysis goes at the next change; what is shown stays.
    return .{
        .start = found.span.start,
        .end = found.span.end,
        .code = try arena.dupe(u8, found.code),
        .doc = if (found.doc) |d| try arena.dupe(u8, d) else null,
    };
}

fn definition(_: ?*anyopaque, state: ?*anyopaque, arena: Allocator, offset: u32) code.Error!?code.Definition {
    const a = analysisOf(state) orelse return null;
    const decl = a.definition(offset) orelse return null;
    const path: ?[]const u8 = if (decl.file == a.file) null else try arena.dupe(u8, a.fileName(decl.file));
    return .{ .path = path, .start = decl.span.start, .end = decl.span.end };
}

/// The style of a token of the kind the service says it is.
fn styleOf(kind: service.TokenType, modifiers: service.Modifiers) code.Style {
    return switch (kind) {
        .keyword => .keyword,
        .comment => if (modifiers.documentation) .doc_comment else .comment,
        .string => .string,
        .number => .number,
        .operator => .operator,
        .decorator => .annotation,
        .type, .namespace => .type,
        .@"struct", .@"enum" => .declared_type,
        .function, .method => if (modifiers.default_library) .library_function else .function,
        .property => .property,
        .enum_member => .enum_member,
        .event => .signal,
        .parameter => .parameter,
        .variable => if (modifiers.readonly and !modifiers.declaration) .constant else .variable,
    };
}

fn kindOf(kind: service.Kind) code.ItemKind {
    return switch (kind) {
        .variable => .variable,
        .constant => .constant,
        .parameter => .parameter,
        .function, .builtin_function, .@"test" => .function,
        .method, .builtin_method => .method,
        .field => .field,
        .property => .property,
        .signal => .signal,
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .enum_member => .enum_member,
        .module => .module,
        .builtin_type => .type,
        .keyword => .keyword,
        .annotation => .annotation,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const metrics: code.Metrics = .{ .font_size = 16, .line_height = 18 };

test "completions narrow as the word is typed, and a mistake is found once it is made" {
    var flux_lang: Flux = .{};
    var ed: code.Document = try .init(testing.allocator, "t.flux", "fn fight(rounds: int) {\n    \n}\n", flux_lang.language(), metrics);
    defer ed.deinit();
    ed.buffer.moveTo(28, false);
    for ("rou") |c| try ed.typeChar(c);
    try testing.expect(ed.completion.open);
    try testing.expectEqualStrings("rounds", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try testing.expectEqualStrings("fn fight(rounds: int) {\n    rounds\n}\n", ed.buffer.text.items);
    try ed.typeChar('.');
    try testing.expect(!ed.completion.open);
    ed.refresh();
    try testing.expect(ed.problems.len > 0);
    try testing.expectEqual(@as(u32, 1), ed.problems[0].line);
}

test "names are coloured by what they name" {
    var flux_lang: Flux = .{};
    var ed: code.Document = try .init(testing.allocator, "t.flux", "struct Ball {}\nfn roll(b: Ball) {}\n", flux_lang.language(), metrics);
    defer ed.deinit();
    ed.refresh();
    var saw_type = false;
    var saw_function = false;
    var saw_keyword = false;
    for (ed.tokens) |t| switch (t.style) {
        .declared_type => saw_type = true,
        .function => saw_function = true,
        .keyword => saw_keyword = true,
        else => {},
    };
    try testing.expect(saw_type and saw_function and saw_keyword);
    try testing.expectEqual(@as(usize, 2), ed.symbols.len);
}

test "go to definition selects the name where it is declared" {
    const text = "struct Ball {\n    var x: int = 0;\n}\nfn f() {\n    var b = Ball{};\n    print(b.x);\n}\n";
    var flux_lang: Flux = .{};
    var ed: code.Document = try .init(testing.allocator, "t.flux", text, flux_lang.language(), metrics);
    defer ed.deinit();
    ed.goToDefinition(@intCast(std.mem.indexOf(u8, text, "Ball{}").? + 2));
    try testing.expectEqualStrings("Ball", ed.buffer.selectedText());
    try testing.expectEqual(@as(u32, 0), ed.buffer.lineOf(ed.buffer.cursor));
    ed.goToDefinition(@intCast(std.mem.indexOf(u8, text, "b.x").? + 2));
    try testing.expectEqualStrings("x", ed.buffer.selectedText());
    try testing.expectEqual(@as(u32, 1), ed.buffer.lineOf(ed.buffer.cursor));
}

test "a function is completed with its parentheses, and its signature shown" {
    var flux_lang: Flux = .{};
    var ed: code.Document = try .init(testing.allocator, "t.flux", "fn heal(amount: int) {}\nfn f() {\n    \n}\n", flux_lang.language(), metrics);
    defer ed.deinit();
    ed.buffer.moveTo(@intCast(std.mem.indexOf(u8, ed.buffer.text.items, "    \n").? + 4), false);
    for ("hea") |c| try ed.typeChar(c);
    try testing.expectEqualStrings("heal", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try testing.expect(std.mem.indexOf(u8, ed.buffer.text.items, "    heal()\n") != null);
    try testing.expectEqual(@as(u8, ')'), ed.buffer.text.items[ed.buffer.cursor]);
    try testing.expectEqualStrings("heal(amount: int)", ed.signature.?.label);
}

test "what the pointer rests on is shown, after a moment" {
    var flux_lang: Flux = .{};
    var ed: code.Document = try .init(testing.allocator, "t.flux", "/// Rolls it.\nfn roll() {}\nfn f() { roll(); }\n", flux_lang.language(), metrics);
    defer ed.deinit();
    ed.refresh();
    const at: u32 = @intCast(std.mem.lastIndexOf(u8, ed.buffer.text.items, "roll").? + 1);
    ed.rest(at);
    ed.now = 1;
    ed.rest(at);
    const shown = ed.hover.shown orelse return error.TestExpectedEqual;
    try testing.expect(std.mem.indexOf(u8, shown.code, "roll") != null);
    try testing.expectEqualStrings("Rolls it.", std.mem.trim(u8, shown.doc.?, " \n"));
}

/// The actions a test's host knows, for `app.actionDown` and nothing else.
fn actionNames(_: ?*anyopaque, arena: Allocator, at: service.StringArgument) Allocator.Error![]const service.StringValue {
    _ = arena;
    const receiver = at.receiver orelse return &.{};
    if (!std.mem.eql(u8, receiver, "app") or !std.mem.eql(u8, at.callee, "actionDown")) return &.{};
    return &.{ .{ .label = "jump" }, .{ .label = "jump_high" }, .{ .label = "crouch" } };
}

test "a quote opened for a call the host knows the strings of offers them, and a pick goes inside it" {
    var flux_lang: Flux = .{ .options = .{ .strings = .{ .values = actionNames } } };
    var ed: code.Document = try .init(testing.allocator, "t.flux", "fn f(app: any) {\n    if (app.actionDown(\n}\n", flux_lang.language(), metrics);
    defer ed.deinit();
    ed.buffer.moveTo(@intCast(std.mem.indexOf(u8, ed.buffer.text.items, "(\n}").? + 1), false);
    try ed.typeChar('"');
    try testing.expect(ed.completion.open);
    for ("cr") |c| try ed.typeChar(c);
    try testing.expectEqualStrings("crouch", ed.selectedItem().?.label);
    try ed.accept(ed.completion.selected);
    try testing.expect(std.mem.indexOf(u8, ed.buffer.text.items, "app.actionDown(\"crouch\"") != null);
}

test "a colour's name is offered in color's quotes with its swatch, and Flux's colours have swatches of their own" {
    const gpa = testing.allocator;
    var flux_lang: Flux = .{};
    var ed: code.Document = try .init(gpa, "t.flux", "const a = color(\"ro\");\nconst b = hsv(240, 1, 1);\nconst c = color(0.5, 0.5, 0.5);\n", flux_lang.language(), metrics);
    defer ed.deinit();
    ed.buffer.moveTo(19, false);
    ed.complete();
    try testing.expect(ed.completion.open);
    const item = ed.selectedItem() orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("rosybrown", item.label);
    try testing.expectEqual([4]f32{ 188.0 / 255.0, 143.0 / 255.0, 143.0 / 255.0, 1 }, item.swatch.?);
    _ = try ed.key(.down, .{});
    _ = try ed.key(.enter, .{});
    try testing.expect(std.mem.startsWith(u8, ed.buffer.text.items, "const a = color(\"royalblue\");"));

    ed.refresh();
    try testing.expectEqual(@as(usize, 3), ed.colors.len);
    try testing.expectEqual(@as(f32, 0x41) / 255, ed.colors[0].color.r);
    try testing.expectEqual(@as(f32, 1), ed.colors[1].color.b);
    // Written back in another of Flux's ways.
    try testing.expect(try ed.setColor(ed.colors[2].start, ed.colors[2].color, 1));
    try testing.expect(std.mem.endsWith(u8, ed.buffer.text.items, "const c = color(\"#808080\");\n"));
}
