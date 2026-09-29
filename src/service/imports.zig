// SPDX-License-Identifier: BSD-2-Clause

//! What an editor needs to help with imports: whether the cursor is inside
//! an `@import("...")`'s quotes, what a file declares at its top, what it
//! imports already, and where and under what name an import of another file
//! goes when one of its names is taken.

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const lex = @import("../syntax/lex.zig");
const token = @import("../syntax/token.zig");
const Token = token.Token;
const Kind = @import("../service.zig").Kind;

fn tokenize(gpa: Allocator, source: []const u8) Allocator.Error![]Token {
    var sink: diag.Diagnostics = .init(gpa);
    defer sink.deinit();
    return lex.tokenizeRange(gpa, source, 0, source.len, .none, &sink);
}

/// The text inside the quotes of the `@import("...")` the cursor is in,
/// the closing quote typed or not yet; null anywhere else.
pub fn importString(gpa: Allocator, source: []const u8, offset: u32) Allocator.Error!?[2]u32 {
    const cursor: u32 = @min(offset, @as(u32, @intCast(source.len)));
    const tokens = try tokenize(gpa, source);
    defer gpa.free(tokens);
    for (tokens, 0..) |t, k| {
        if (t.kind != .string or k < 2 or source[t.start] != '"') continue;
        if (tokens[k - 1].kind != .l_paren or tokens[k - 2].kind != .builtin) continue;
        if (!std.mem.eql(u8, source[tokens[k - 2].start..tokens[k - 2].end], "@import")) continue;
        const closed = t.end - t.start >= 2 and source[t.end - 1] == '"';
        const end = if (closed) t.end - 1 else t.end;
        if (cursor > t.start and cursor <= end) return .{ t.start + 1, end };
    }
    return null;
}

/// A name a file declares at its top.
pub const Decl = struct {
    name: []const u8,
    kind: Kind,
};

/// An import a file has at its top: `const save = @import("res://save.flux");`.
pub const Import = struct {
    name: []const u8,
    path: []const u8,
    /// Just past the end of its line: where the next import goes.
    after: u32,
};

/// What a file declares and imports at its top: its structs, enums,
/// functions, constants and variables, in `arena`.
pub const Top = struct {
    decls: []const Decl,
    imports: []const Import,

    /// Where an import is put: after the last one it has, or else after the
    /// comments and blank lines it starts with.
    pub fn importPlace(self: Top, source: []const u8) u32 {
        var at: u32 = 0;
        for (self.imports) |i| at = @max(at, i.after);
        if (self.imports.len > 0) return at;
        var line: u32 = 0;
        while (line < source.len) {
            const end: u32 = if (std.mem.indexOfScalarPos(u8, source, line, '\n')) |n| @intCast(n + 1) else @intCast(source.len);
            const text = std.mem.trim(u8, source[line..end], " \t\r\n");
            if (text.len > 0 and !std.mem.startsWith(u8, text, "//")) break;
            line = end;
        }
        return line;
    }

    /// Whether the file has a declaration or an import called `name`.
    pub fn has(self: Top, name: []const u8) bool {
        for (self.decls) |d| if (std.mem.eql(u8, d.name, name)) return true;
        for (self.imports) |i| if (std.mem.eql(u8, i.name, name)) return true;
        return false;
    }

    /// The name the file imports `path` under, if it does.
    pub fn importOf(self: Top, path: []const u8) ?[]const u8 {
        for (self.imports) |i| if (std.mem.eql(u8, i.path, path)) return i.name;
        return null;
    }
};

pub fn top(gpa: Allocator, arena: Allocator, source: []const u8) Allocator.Error!Top {
    const tokens = try tokenize(gpa, source);
    defer gpa.free(tokens);
    var decls: std.ArrayList(Decl) = .empty;
    var imports: std.ArrayList(Import) = .empty;
    var depth: usize = 0;
    var k: usize = 0;
    while (k < tokens.len) : (k += 1) {
        const t = tokens[k];
        switch (t.kind) {
            .l_brace, .l_paren, .l_bracket => depth += 1,
            .r_brace, .r_paren, .r_bracket => depth -|= 1,
            else => {},
        }
        if (depth != 0 or k + 1 >= tokens.len or tokens[k + 1].kind != .identifier) continue;
        const name = source[tokens[k + 1].start..tokens[k + 1].end];
        const kind: Kind = switch (t.kind) {
            .kw_struct => .@"struct",
            .kw_enum => .@"enum",
            .kw_fn => .function,
            .kw_var => .variable,
            .kw_const => .constant,
            else => continue,
        };
        // `const name = @import("path")`: an import, not a declaration.
        if (kind == .constant and k + 5 < tokens.len and tokens[k + 2].kind == .equal and tokens[k + 3].kind == .builtin and
            std.mem.eql(u8, source[tokens[k + 3].start..tokens[k + 3].end], "@import") and tokens[k + 4].kind == .l_paren and tokens[k + 5].kind == .string)
        {
            const s = tokens[k + 5];
            const after: u32 = if (std.mem.indexOfScalarPos(u8, source, s.end, '\n')) |n| @intCast(n + 1) else @intCast(source.len);
            try imports.append(arena, .{ .name = try arena.dupe(u8, name), .path = try arena.dupe(u8, std.mem.trim(u8, source[s.start..s.end], "\"")), .after = after });
            continue;
        }
        try decls.append(arena, .{ .name = try arena.dupe(u8, name), .kind = kind });
    }
    return .{ .decls = decls.items, .imports = imports.items };
}

/// The name a file at `path` is imported under: its name without its
/// ending, made a name a script can write, and another where `taken` has it.
pub fn aliasFor(arena: Allocator, path: []const u8, taken: Top) Allocator.Error![]const u8 {
    const file = std.fs.path.stem(std.fs.path.basename(path));
    var base: std.ArrayList(u8) = .empty;
    for (file) |c| try base.append(arena, if (std.ascii.isAlphanumeric(c) or c == '_') c else '_');
    if (base.items.len == 0 or std.ascii.isDigit(base.items[0])) try base.insert(arena, 0, '_');
    if (token.keywords.get(base.items) != null) try base.append(arena, '_');
    if (!taken.has(base.items)) return base.items;
    var n: usize = 2;
    while (true) : (n += 1) {
        const numbered = try std.fmt.allocPrint(arena, "{s}{d}", .{ base.items, n });
        if (!taken.has(numbered)) return numbered;
    }
}

test "the cursor in an import's quotes, closed or not" {
    const gpa = std.testing.allocator;
    const Case = struct { source: []const u8, found: bool };
    for ([_]Case{
        .{ .source = "const a = @import(\"ma$", .found = true },
        .{ .source = "const a = @import(\"res://li$b.flux\");", .found = true },
        .{ .source = "const a = @import(\"$\")", .found = true },
        .{ .source = "print(\"ma$\")", .found = false },
        .{ .source = "const a = @import(\"math\")$;", .found = false },
    }) |case| {
        const where = std.mem.indexOfScalar(u8, case.source, '$').?;
        const source = try std.mem.concat(gpa, u8, &.{ case.source[0..where], case.source[where + 1 ..] });
        defer gpa.free(source);
        const at = try importString(gpa, source, @intCast(where));
        try std.testing.expectEqual(case.found, at != null);
    }
}

test "a file's top: its declarations, its imports and where the next goes, and a name for another" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\// The shop.
        \\const math = @import("math");
        \\const save = @import("res://save.flux");
        \\
        \\struct Shop {
        \\    var stock = 0;
        \\    fn sell(self) {}
        \\}
        \\enum Coin { gold }
        \\fn open() {}
        \\var price = 3;
        \\
    ;
    const t = try top(std.testing.allocator, arena, source);
    try std.testing.expectEqual(@as(usize, 4), t.decls.len);
    try std.testing.expectEqualStrings("Shop", t.decls[0].name);
    try std.testing.expectEqual(Kind.@"enum", t.decls[1].kind);
    try std.testing.expectEqualStrings("save", t.importOf("res://save.flux").?);
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "\n\nstruct").? + 1)), t.importPlace(source));
    try std.testing.expectEqualStrings("save2", try aliasFor(arena, "res://items/save.flux", t));
    try std.testing.expectEqualStrings("my_list", try aliasFor(arena, "res://my-list.flux", t));

    // With no import yet, one goes after the comments at the top.
    const bare = try top(std.testing.allocator, arena, "// A note.\n\nfn go() {}\n");
    try std.testing.expectEqual(@as(u32, 12), bare.importPlace("// A note.\n\nfn go() {}\n"));
}
