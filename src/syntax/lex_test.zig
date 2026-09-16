// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;

const diag = @import("../diag.zig");
const lex = @import("lex.zig");
const Kind = @import("token.zig").Kind;

const Lexed = struct {
    kinds: []Kind,
    texts: [][]const u8,
    diags: diag.Diagnostics,

    fn deinit(l: *Lexed) void {
        testing.allocator.free(l.kinds);
        testing.allocator.free(l.texts);
        l.diags.deinit();
    }
};

fn lexAll(source: []const u8) !Lexed {
    var diags: diag.Diagnostics = .init(testing.allocator);
    errdefer diags.deinit();
    const tokens = try lex.tokenize(testing.allocator, source, @enumFromInt(0), &diags);
    defer testing.allocator.free(tokens);
    const kinds = try testing.allocator.alloc(Kind, tokens.len);
    errdefer testing.allocator.free(kinds);
    const texts = try testing.allocator.alloc([]const u8, tokens.len);
    for (tokens, kinds, texts) |t, *k, *s| {
        k.* = t.kind;
        s.* = t.text(source);
    }
    return .{ .kinds = kinds, .texts = texts, .diags = diags };
}

fn expectKinds(source: []const u8, expected: []const Kind) !void {
    var l = try lexAll(source);
    defer l.deinit();
    try testing.expectEqualSlices(Kind, expected, l.kinds);
    try testing.expect(!l.diags.failed());
}

test "declarations and punctuation" {
    try expectKinds("const x: int = 5;", &.{ .kw_const, .identifier, .colon, .identifier, .equal, .int, .semicolon, .eof });
    try expectKinds("struct Boss extends Enemy { }", &.{ .kw_struct, .identifier, .kw_extends, .identifier, .l_brace, .r_brace, .eof });
}

test "the longest operator wins" {
    try expectKinds("a <<= b >>= c +%= d .. e ..= f ... g => h", &.{
        .identifier, .shl_equal,     .identifier, .shr_equal, .identifier, .plus_percent_equal,
        .identifier, .dot_dot,       .identifier, .dot_dot_equal, .identifier, .ellipsis,
        .identifier, .fat_arrow,     .identifier, .eof,
    });
    try expectKinds("x.? != y == z", &.{ .identifier, .dot, .question, .bang_equal, .identifier, .equal_equal, .identifier, .eof });
}

test "numbers in every base, with separators" {
    var l = try lexAll("1_000 0xFF 0b1010 0o17 1.5 2e10 3.0e-2 1..5");
    defer l.deinit();
    try testing.expectEqualSlices(Kind, &.{ .int, .int, .int, .int, .float, .float, .float, .int, .dot_dot, .int, .eof }, l.kinds);
    try testing.expectEqualStrings("1_000", l.texts[0]);
    try testing.expectEqualStrings("3.0e-2", l.texts[6]);
}

test "a method on a number is not a fraction" {
    try expectKinds("1.len", &.{ .int, .dot, .identifier, .eof });
}

test "strings, f-strings, characters and builtins" {
    var l = try lexAll(
        \\"a \"quoted\" word" f"hp {self.hp:.1} {m["key"]} {{x}}" 'a' '\n' @import @export
    );
    defer l.deinit();
    try testing.expectEqualSlices(Kind, &.{ .string, .fstring, .char, .char, .builtin, .builtin, .eof }, l.kinds);
    try testing.expectEqualStrings("f\"hp {self.hp:.1} {m[\"key\"]} {{x}}\"", l.texts[1]);
    try testing.expectEqualStrings("@import", l.texts[4]);
}

test "a line of a multiline string is one token without its line break" {
    var l = try lexAll("const s =\n    \\\\first\r\n    \\\\second\n;");
    defer l.deinit();
    try testing.expectEqualSlices(Kind, &.{ .kw_const, .identifier, .equal, .multiline_string, .multiline_string, .semicolon, .eof }, l.kinds);
    try testing.expectEqualStrings("\\\\first", l.texts[3]);
}

test "comments are skipped, both kinds" {
    try expectKinds("a // line\n/* block\n over lines */ b /// doc\nc", &.{ .identifier, .identifier, .identifier, .eof });
}

test "keywords are keywords, the rest are names" {
    try expectKinds("fn var and or orelse catch try await signal selfish", &.{ .kw_fn, .kw_var, .kw_and, .kw_or, .kw_orelse, .kw_catch, .kw_try, .kw_await, .kw_signal, .identifier, .eof });
}

test "mistakes are reported and lexing goes on" {
    var l = try lexAll("var a = 1 # 2;\nvar b = \"open\nvar é = 12abc;");
    defer l.deinit();
    try testing.expectEqual(@as(u32, 4), l.diags.errors);
    try testing.expectEqualStrings("`#` is not part of the language", l.diags.items.items[0].message);
    try testing.expectEqualStrings("this string is never closed", l.diags.items.items[1].message);
    try testing.expectEqualStrings("`é` cannot appear outside a string or a comment", l.diags.items.items[2].message);
    try testing.expectEqualStrings("`12abc` is not a number", l.diags.items.items[3].message);
    try testing.expectEqual(Kind.eof, l.kinds[l.kinds.len - 1]);
}

test "an unclosed block comment is reported once" {
    var l = try lexAll("a /* never");
    defer l.deinit();
    try testing.expectEqual(@as(u32, 1), l.diags.errors);
    try testing.expectEqualSlices(Kind, &.{ .identifier, .eof }, l.kinds);
}

test "an unclosed f-string stops at the line end" {
    var l = try lexAll("f\"{a\nb");
    defer l.deinit();
    try testing.expectEqual(@as(u32, 1), l.diags.errors);
    try testing.expectEqualSlices(Kind, &.{ .fstring, .identifier, .eof }, l.kinds);
}
