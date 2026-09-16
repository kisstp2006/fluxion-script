// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag = @import("../diag.zig");
const ast = @import("ast.zig");
const lex = @import("lex.zig");
const token = @import("token.zig");
const expr = @import("parse_expr.zig");
const stmt = @import("parse_stmt.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = ast.Span;

pub const Error = error{ OutOfMemory, Syntax };

pub const Parser = struct {
    arena: Allocator,
    gpa: Allocator,
    source: []const u8,
    tokens: []const Token,
    pos: usize = 0,
    file: diag.FileId,
    diags: *diag.Diagnostics,
    /// How deep expressions, statements and types are nested where the
    /// parser is. Past `max_depth` the source is refused, before the parser
    /// - and the compiler after it, walking the same tree - runs out of
    /// stack.
    depth: u32 = 0,

    pub const max_depth = 200;

    pub fn enter(p: *Parser) Error!void {
        if (p.depth == max_depth) return p.fail(spanOf(p.current()), "this is nested more than {d} deep", .{max_depth});
        p.depth += 1;
    }

    pub fn leave(p: *Parser) void {
        p.depth -= 1;
    }

    pub fn peek(p: *const Parser) Kind {
        return p.tokens[p.pos].kind;
    }

    pub fn peekAt(p: *const Parser, n: usize) Kind {
        return p.tokens[@min(p.pos + n, p.tokens.len - 1)].kind;
    }

    pub fn current(p: *const Parser) Token {
        return p.tokens[p.pos];
    }

    pub fn previous(p: *const Parser) Token {
        return p.tokens[if (p.pos == 0) 0 else p.pos - 1];
    }

    pub fn advance(p: *Parser) Token {
        const t = p.tokens[p.pos];
        if (t.kind != .eof) p.pos += 1;
        return t;
    }

    pub fn eat(p: *Parser, kind: Kind) ?Token {
        if (p.peek() != kind) return null;
        return p.advance();
    }

    pub fn check(p: *const Parser, kind: Kind) bool {
        return p.peek() == kind;
    }

    pub fn textOf(p: *const Parser, t: Token) []const u8 {
        return t.text(p.source);
    }

    pub fn spanOf(t: Token) Span {
        return .{ .start = t.start, .end = t.end };
    }

    pub fn spanFrom(p: *const Parser, start: u32) Span {
        return .{ .start = start, .end = @max(start, p.previous().end) };
    }

    pub fn at(p: *const Parser, span: Span) diag.Location {
        return .{ .file = p.file, .span = span };
    }

    pub fn new(p: *Parser, comptime T: type, value: T) Allocator.Error!*T {
        const ptr = try p.arena.create(T);
        ptr.* = value;
        return ptr;
    }

    pub fn fail(p: *Parser, span: Span, comptime fmt: []const u8, args: anytype) Error {
        _ = try p.diags.err(p.at(span), fmt, args);
        return error.Syntax;
    }

    /// Nothing more is said about a token the lexer already complained of.
    /// What is missing at the end of a line is marked there, rather than at
    /// whatever the next line starts with.
    pub fn failHere(p: *Parser, what: []const u8) Error {
        const t = p.current();
        if (t.kind == .invalid) return error.Syntax;
        const h = if (p.pos > 0 and p.newlineBefore(p.pos))
            try (try p.diags.err(p.at(.at(p.previous().end)), "expected {s}, found {s}", .{ what, try found(p, t) })).label(p.at(spanOf(t)), "found {s}", .{try found(p, t)})
        else
            try p.diags.err(p.at(spanOf(t)), "expected {s}, found {s}", .{ what, try found(p, t) });
        _ = try h.text("expected {s}", .{what});
        return error.Syntax;
    }

    pub fn expect(p: *Parser, kind: Kind, what: []const u8) Error!Token {
        if (p.eat(kind)) |t| return t;
        const t = p.current();
        if (t.kind == .invalid) return error.Syntax;
        const sep: []const u8 = if (what.len > 0) " " else "";
        if (kind == .semicolon or kind == .r_paren or kind == .r_bracket) {
            const after = p.previous().end;
            _ = try (try (try p.diags.err(p.at(.at(after)), "expected {s}{s}{s}", .{ kind.describe(), sep, what }))
                .text("add {s} here", .{kind.describe()}))
                .label(p.at(spanOf(t)), "found {s}", .{try found(p, t)});
            return error.Syntax;
        }
        _ = try (try p.diags.err(p.at(spanOf(t)), "expected {s}{s}{s}, found {s}", .{ kind.describe(), sep, what, try found(p, t) }))
            .text("expected {s}", .{kind.describe()});
        return error.Syntax;
    }

    /// The `;` that ends a statement. One left out is reported, and when the
    /// line ends there the statement is kept all the same: what it declares
    /// and uses stays known, to the rest of the file and to an editor asking
    /// about the line being typed.
    pub fn semicolon(p: *Parser, what: []const u8) Error!void {
        if (p.eat(.semicolon) != null) return;
        const line_ends = p.newlineBefore(p.pos) or p.check(.r_brace) or p.check(.eof);
        if (p.expect(.semicolon, what)) |_| {} else |err| {
            if (err == error.OutOfMemory or !line_ends) return err;
        }
    }

    pub fn expectName(p: *Parser, comptime what: []const u8) Error!ast.Name {
        const t = p.current();
        if (t.kind == .identifier) {
            _ = p.advance();
            return .{ .text = p.textOf(t), .span = spanOf(t) };
        }
        // A keyword starting the next line is what follows a name not yet
        // written, not a name.
        if (t.kind.isKeyword() and !p.newlineBefore(p.pos)) {
            _ = try (try p.diags.err(p.at(spanOf(t)), "`{s}` is a keyword and cannot be " ++ what, .{p.textOf(t)}))
                .help("pick another name, such as `{s}_`", .{p.textOf(t)});
            return error.Syntax;
        }
        return p.failHere(what);
    }

    /// The `///` lines just above the token at `index`, joined.
    pub fn docBefore(p: *Parser, index: usize) Allocator.Error!?[]const u8 {
        const end = p.tokens[index].start;
        const begin: u32 = if (index == 0) 0 else p.tokens[index - 1].end;
        const gap = p.source[begin..end];
        var lines = std.mem.splitBackwardsScalar(u8, gap, '\n');
        var collected: std.ArrayList([]const u8) = .empty;
        _ = lines.next();
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, "///")) break;
            const body = line[3..];
            try collected.append(p.arena, if (body.len > 0 and body[0] == ' ') body[1..] else body);
        }
        if (collected.items.len == 0) return null;
        std.mem.reverse([]const u8, collected.items);
        return try std.mem.join(p.arena, "\n", collected.items);
    }

    pub fn newlineBefore(p: *const Parser, index: usize) bool {
        if (index == 0) return true;
        const gap = p.source[p.tokens[index - 1].end..p.tokens[index].start];
        return std.mem.indexOfScalar(u8, gap, '\n') != null;
    }

    /// Skips to where the next statement probably starts, so one mistake is
    /// reported once rather than as every token after it.
    pub fn synchronize(p: *Parser) void {
        var depth: usize = 0;
        while (true) {
            const k = p.peek();
            switch (k) {
                .eof => return,
                .l_brace => depth += 1,
                .r_brace => {
                    if (depth == 0) return;
                    depth -= 1;
                    if (depth == 0) {
                        _ = p.advance();
                        if (p.newlineBefore(p.pos)) return;
                        continue;
                    }
                },
                .semicolon => if (depth == 0) {
                    _ = p.advance();
                    return;
                },
                .kw_var, .kw_const, .kw_fn, .kw_struct, .kw_enum, .kw_if, .kw_while, .kw_for, .kw_return, .kw_test, .kw_signal, .kw_defer, .kw_switch => {
                    if (depth == 0 and p.newlineBefore(p.pos)) return;
                },
                else => {},
            }
            _ = p.advance();
        }
    }
};

pub fn found(p: *const Parser, t: Token) Allocator.Error![]const u8 {
    const bytes = p.textOf(t);
    return switch (t.kind) {
        .identifier, .int, .float => if (bytes.len <= 32) try std.fmt.allocPrint(p.arena, "`{s}`", .{bytes}) else t.kind.describe(),
        else => t.kind.describe(),
    };
}

pub fn parse(arena: Allocator, gpa: Allocator, source: []const u8, file: diag.FileId, diags: *diag.Diagnostics) Allocator.Error!ast.Module {
    const tokens = try lex.tokenize(gpa, source, file, diags);
    defer gpa.free(tokens);
    var p: Parser = .{ .arena = arena, .gpa = gpa, .source = source, .tokens = tokens, .file = file, .diags = diags };
    var stmts: std.ArrayList(*ast.Stmt) = .empty;
    while (!p.check(.eof)) {
        if (p.diags.full()) break;
        const start = p.pos;
        const s = stmt.topLevel(&p) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => blk: {
                if (p.pos == start) _ = p.advance();
                p.synchronize();
                break :blk try p.new(ast.Stmt, .{ .span = .at(p.tokens[start].start), .kind = .invalid });
            },
        };
        try stmts.append(arena, s);
    }
    return .{ .stmts = stmts.items };
}

pub fn annotations(p: *Parser) Error![]const ast.Annotation {
    var list: std.ArrayList(ast.Annotation) = .empty;
    while (p.check(.builtin)) {
        const t = p.advance();
        const name: ast.Name = .{ .text = p.textOf(t)[1..], .span = Parser.spanOf(t) };
        var args: []const *ast.Expr = &.{};
        if (p.eat(.l_paren)) |_| args = try expr.arguments(p);
        try list.append(p.arena, .{ .name = name, .args = args });
    }
    return list.items;
}

pub fn typeExpr(p: *Parser) Error!*ast.TypeExpr {
    try p.enter();
    defer p.leave();
    const t = p.current();
    const start = t.start;
    switch (t.kind) {
        .question => {
            _ = p.advance();
            const child = try typeExpr(p);
            return p.new(ast.TypeExpr, .{ .span = p.spanFrom(start), .kind = .{ .optional = child } });
        },
        .bang => {
            _ = p.advance();
            const child = try typeExpr(p);
            return p.new(ast.TypeExpr, .{ .span = p.spanFrom(start), .kind = .{ .error_union = child } });
        },
        .l_bracket => {
            _ = p.advance();
            const first = try typeExpr(p);
            if (p.eat(.colon)) |_| {
                const value = try typeExpr(p);
                _ = try p.expect(.r_bracket, "to close the map type");
                return p.new(ast.TypeExpr, .{ .span = p.spanFrom(start), .kind = .{ .map = .{ .key = first, .value = value } } });
            }
            _ = try p.expect(.r_bracket, "to close the list type");
            return p.new(ast.TypeExpr, .{ .span = p.spanFrom(start), .kind = .{ .list = first } });
        },
        .kw_fn => {
            _ = p.advance();
            _ = try p.expect(.l_paren, "after `fn` in a function type");
            var param_types: std.ArrayList(*ast.TypeExpr) = .empty;
            while (!p.check(.r_paren)) {
                try param_types.append(p.arena, try typeExpr(p));
                if (p.eat(.comma) == null) break;
            }
            _ = try p.expect(.r_paren, "to close the parameter types");
            const ret = if (startsType(p.peek())) try typeExpr(p) else null;
            return p.new(ast.TypeExpr, .{ .span = p.spanFrom(start), .kind = .{ .func = .{ .params = param_types.items, .ret = ret } } });
        },
        .identifier, .kw_error => {
            _ = p.advance();
            const first = p.textOf(t);
            if (p.check(.dot) and p.peekAt(1) == .identifier) {
                _ = p.advance();
                const second = p.textOf(p.advance());
                return p.new(ast.TypeExpr, .{ .span = p.spanFrom(start), .kind = .{ .member = .{ .module = first, .name = second } } });
            }
            return p.new(ast.TypeExpr, .{ .span = p.spanFrom(start), .kind = .{ .name = first } });
        },
        .kw_null => {
            _ = p.advance();
            return p.new(ast.TypeExpr, .{ .span = p.spanFrom(start), .kind = .{ .name = "null" } });
        },
        else => return p.failHere("a type"),
    }
}

pub fn startsType(kind: Kind) bool {
    return switch (kind) {
        .question, .bang, .l_bracket, .kw_fn, .identifier, .kw_error, .kw_null => true,
        else => false,
    };
}

pub fn params(p: *Parser, allow_self: bool) Error![]const ast.Param {
    var list: std.ArrayList(ast.Param) = .empty;
    while (!p.check(.r_paren)) {
        if (p.check(.kw_self)) {
            const t = p.advance();
            if (!allow_self or list.items.len > 0) {
                _ = try (try p.diags.err(p.at(Parser.spanOf(t)), "`self` can only be the first parameter of a method", .{}))
                    .text("not allowed here", .{});
                return error.Syntax;
            }
            try list.append(p.arena, .{ .name = .{ .text = "self", .span = Parser.spanOf(t) }, .type = null, .default = null, .is_self = true });
        } else {
            const name = try p.expectName("a parameter name");
            const ty = if (p.eat(.colon)) |_| try typeExpr(p) else null;
            const default = if (p.eat(.equal)) |_| try expr.expression(p) else null;
            if (default == null) {
                for (list.items) |prior| if (prior.default != null) {
                    _ = try (try p.diags.err(p.at(name.span), "`{s}` needs a default value, because a parameter before it has one", .{name.text}))
                        .text("give this a default too", .{});
                    break;
                };
            }
            try list.append(p.arena, .{ .name = name, .type = ty, .default = default, .is_self = false });
        }
        if (p.eat(.comma) == null) break;
    }
    _ = try p.expect(.r_paren, "to close the parameters");
    return list.items;
}

pub fn function(p: *Parser, attrs: []const ast.Annotation, doc: ?[]const u8, allow_self: bool) Error!*ast.Fn {
    const start = (try p.expect(.kw_fn, "")).start;
    const name = try p.expectName("a function name");
    _ = try p.expect(.l_paren, "after the function name");
    const ps = try params(p, allow_self);
    const ret = if (!p.check(.l_brace)) try typeExpr(p) else null;
    const body = try stmt.block(p);
    return p.new(ast.Fn, .{
        .span = p.spanFrom(start),
        .name = name,
        .params = ps,
        .ret = ret,
        .body = .{ .block = body },
        .annotations = attrs,
        .doc = doc,
    });
}

pub fn varDecl(p: *Parser, attrs: []const ast.Annotation, doc: ?[]const u8) Error!*ast.VarDecl {
    const keyword = p.advance();
    const name = try p.expectName("a variable name");
    const decl = try p.new(ast.VarDecl, .{
        .span = .empty,
        .is_const = keyword.kind == .kw_const,
        .name = name,
        .type = null,
        .value = null,
        .annotations = attrs,
        .doc = doc,
    });
    // Once the name is read, a mistake after it keeps the declaration, so
    // each use of the variable is not reported again as undeclared.
    varRest(p, decl) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            if (decl.value == null) decl.value = try p.new(ast.Expr, .{ .span = .at(p.current().start), .kind = .invalid });
            p.synchronize();
        },
    };
    decl.span = p.spanFrom(keyword.start);
    return decl;
}

fn varRest(p: *Parser, decl: *ast.VarDecl) Error!void {
    if (p.eat(.colon)) |_| decl.type = try typeExpr(p);
    if (p.eat(.equal)) |_| decl.value = try expr.expression(p);
    try p.semicolon("after the declaration");
}

pub fn structDecl(p: *Parser, attrs: []const ast.Annotation, doc: ?[]const u8) Error!*ast.Struct {
    const start = (try p.expect(.kw_struct, "")).start;
    const name = try p.expectName("a struct name");
    const parent = if (p.eat(.kw_extends)) |_| try typeExpr(p) else null;
    _ = try p.expect(.l_brace, "to open the struct");
    var fields: std.ArrayList(*ast.VarDecl) = .empty;
    var consts: std.ArrayList(*ast.VarDecl) = .empty;
    var methods: std.ArrayList(*ast.Fn) = .empty;
    var signals: std.ArrayList(ast.Signal) = .empty;
    while (!p.check(.r_brace) and !p.check(.eof)) {
        const member_start = p.pos;
        member(p, &fields, &consts, &methods, &signals) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => {
                if (p.pos == member_start) _ = p.advance();
                p.synchronize();
            },
        };
    }
    _ = try p.expect(.r_brace, "to close the struct");
    return p.new(ast.Struct, .{
        .span = p.spanFrom(start),
        .name = name,
        .parent = parent,
        .fields = fields.items,
        .consts = consts.items,
        .methods = methods.items,
        .signals = signals.items,
        .annotations = attrs,
        .doc = doc,
    });
}

fn member(
    p: *Parser,
    fields: *std.ArrayList(*ast.VarDecl),
    consts: *std.ArrayList(*ast.VarDecl),
    methods: *std.ArrayList(*ast.Fn),
    signals: *std.ArrayList(ast.Signal),
) Error!void {
    const doc = try p.docBefore(p.pos);
    const attrs = try annotations(p);
    switch (p.peek()) {
        .kw_var => try fields.append(p.arena, try varDecl(p, attrs, doc)),
        .kw_const => try consts.append(p.arena, try varDecl(p, attrs, doc)),
        .kw_fn => try methods.append(p.arena, try function(p, attrs, doc, true)),
        .kw_signal => {
            const start = p.advance().start;
            const name = try p.expectName("a signal name");
            var ps: []const ast.Param = &.{};
            if (p.eat(.l_paren)) |_| ps = try params(p, false);
            _ = try p.expect(.semicolon, "after the signal");
            try signals.append(p.arena, .{ .span = p.spanFrom(start), .name = name, .params = ps, .doc = doc });
        },
        .kw_struct, .kw_enum => return p.fail(Parser.spanOf(p.current()), "a type inside a struct is not supported; declare it at the top of the file", .{}),
        else => return p.failHere("`var`, `const`, `fn` or `signal` in the struct"),
    }
}

pub fn enumDecl(p: *Parser, attrs: []const ast.Annotation, doc: ?[]const u8) Error!*ast.Enum {
    const start = (try p.expect(.kw_enum, "")).start;
    const name = try p.expectName("an enum name");
    _ = try p.expect(.l_brace, "to open the enum");
    var members: std.ArrayList(ast.EnumMember) = .empty;
    var methods: std.ArrayList(*ast.Fn) = .empty;
    while (!p.check(.r_brace) and !p.check(.eof)) {
        if (p.check(.kw_fn) or p.check(.builtin)) {
            const fn_doc = try p.docBefore(p.pos);
            const fn_attrs = try annotations(p);
            try methods.append(p.arena, try function(p, fn_attrs, fn_doc, true));
            continue;
        }
        const member_name = try p.expectName("an enum member");
        const value = if (p.eat(.equal)) |_| try expr.expression(p) else null;
        try members.append(p.arena, .{ .name = member_name, .value = value });
        if (p.eat(.comma) == null) break;
    }
    while (p.check(.kw_fn)) {
        const fn_doc = try p.docBefore(p.pos);
        try methods.append(p.arena, try function(p, &.{}, fn_doc, true));
    }
    _ = try p.expect(.r_brace, "to close the enum");
    return p.new(ast.Enum, .{
        .span = p.spanFrom(start),
        .name = name,
        .members = members.items,
        .methods = methods.items,
        .annotations = attrs,
        .doc = doc,
    });
}
