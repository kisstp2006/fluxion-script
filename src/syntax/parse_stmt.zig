// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

const ast = @import("ast.zig");
const parse = @import("parse.zig");
const expr = @import("parse_expr.zig");

const Parser = parse.Parser;
const Error = parse.Error;
const Stmt = ast.Stmt;

pub fn topLevel(p: *Parser) Error!*Stmt {
    const start = p.current().start;
    const doc = try p.docBefore(p.pos);
    if (p.check(.builtin) and declarationFollowsAnnotations(p)) {
        const attrs = try parse.annotations(p);
        return (try declarationOpt(p, attrs, doc)) orelse
            p.fail(p.spanFrom(start), "an annotation must come before a declaration: `var`, `const`, `fn`, `struct` or `enum`", .{});
    }
    if (p.check(.kw_test)) {
        _ = p.advance();
        const name_token = try p.expect(.string, "naming the test, as in `test \"jumping\" { ... }`");
        const raw = p.textOf(name_token);
        const body = try block(p);
        const t = try p.new(ast.Test, .{ .span = p.spanFrom(start), .name = raw[1..@max(1, raw.len - 1)], .body = body });
        return p.new(Stmt, .{ .span = t.span, .kind = .{ .@"test" = t } });
    }
    if (try declarationOpt(p, &.{}, doc)) |s| return s;
    return statement(p);
}

fn declarationFollowsAnnotations(p: *const Parser) bool {
    var i: usize = 0;
    var depth: usize = 0;
    while (true) : (i += 1) {
        switch (p.peekAt(i)) {
            .l_paren => depth += 1,
            .r_paren => depth -|= 1,
            .kw_var, .kw_const, .kw_fn, .kw_struct, .kw_enum => if (depth == 0) return true,
            .semicolon, .eof, .l_brace => if (depth == 0) return false,
            else => {},
        }
    }
}

fn declarationOpt(p: *Parser, attrs: []const ast.Annotation, doc: ?[]const u8) Error!?*Stmt {
    switch (p.peek()) {
        .kw_var, .kw_const => {
            const v = try parse.varDecl(p, attrs, doc);
            return try p.new(Stmt, .{ .span = v.span, .kind = .{ .@"var" = v } });
        },
        .kw_fn => {
            if (p.peekAt(1) != .identifier) return null;
            const f = try parse.function(p, attrs, doc, false);
            return try p.new(Stmt, .{ .span = f.span, .kind = .{ .@"fn" = f } });
        },
        .kw_struct => {
            const s = try parse.structDecl(p, attrs, doc);
            return try p.new(Stmt, .{ .span = s.span, .kind = .{ .@"struct" = s } });
        },
        .kw_enum => {
            const e = try parse.enumDecl(p, attrs, doc);
            return try p.new(Stmt, .{ .span = e.span, .kind = .{ .@"enum" = e } });
        },
        else => return null,
    }
}

pub fn block(p: *Parser) Error!*ast.Block {
    try p.enter();
    defer p.leave();
    const start = (try p.expect(.l_brace, "to open the block")).start;
    var stmts: std.ArrayList(*Stmt) = .empty;
    while (!p.check(.r_brace) and !p.check(.eof)) {
        if (p.diags.full()) break;
        const before = p.pos;
        const s = inner(p) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => blk: {
                if (p.pos == before) _ = p.advance();
                p.synchronize();
                break :blk try p.new(Stmt, .{ .span = .at(p.tokens[before].start), .kind = .invalid });
            },
        };
        try stmts.append(p.arena, s);
    }
    _ = try p.expect(.r_brace, "to close the block");
    return p.new(ast.Block, .{ .span = p.spanFrom(start), .stmts = stmts.items });
}

fn inner(p: *Parser) Error!*Stmt {
    if (p.check(.kw_struct) or p.check(.kw_enum)) {
        return p.fail(Parser.spanOf(p.current()), "types are declared at the top of a file, not inside a function", .{});
    }
    if (p.check(.builtin) and declarationFollowsAnnotations(p)) {
        const attrs = try parse.annotations(p);
        return (try declarationOpt(p, attrs, null)) orelse p.failHere("a declaration after the annotations");
    }
    if (try declarationOpt(p, &.{}, null)) |s| return s;
    return statement(p);
}

pub fn statement(p: *Parser) Error!*Stmt {
    const t = p.current();
    switch (t.kind) {
        .l_brace => {
            const b = try block(p);
            return p.new(Stmt, .{ .span = b.span, .kind = .{ .block = b } });
        },
        .kw_if => return ifStmt(p),
        .kw_while => return whileStmt(p, null),
        .kw_for => return forStmt(p, null),
        .kw_switch => {
            const sw = try expr.switchBody(p);
            _ = p.eat(.semicolon);
            return p.new(Stmt, .{ .span = p.spanFrom(t.start), .kind = .{ .@"switch" = sw } });
        },
        .kw_defer, .kw_errdefer => {
            _ = p.advance();
            const body = try branch(p);
            if (body.needs_semicolon) try p.semicolon("after the deferred statement");
            return p.new(Stmt, .{ .span = p.spanFrom(t.start), .kind = .{ .@"defer" = .{ .body = body.stmt, .on_error = t.kind == .kw_errdefer } } });
        },
        .identifier => if (p.peekAt(1) == .colon and (p.peekAt(2) == .kw_while or p.peekAt(2) == .kw_for)) {
            const label: ast.Name = .{ .text = p.textOf(t), .span = Parser.spanOf(t) };
            _ = p.advance();
            _ = p.advance();
            return if (p.check(.kw_while)) whileStmt(p, label) else forStmt(p, label);
        },
        else => {},
    }
    const s = try simple(p);
    try p.semicolon("after the statement");
    s.span = p.spanFrom(s.span.start);
    return s;
}

pub fn assignOp(kind: @import("token.zig").Kind) ?ast.AssignOp {
    return switch (kind) {
        .equal => .set,
        .plus_equal => .add,
        .minus_equal => .sub,
        .star_equal => .mul,
        .slash_equal => .div,
        .percent_equal => .mod,
        .plus_percent_equal => .add_wrap,
        .minus_percent_equal => .sub_wrap,
        .star_percent_equal => .mul_wrap,
        .ampersand_equal => .bit_and,
        .pipe_equal => .bit_or,
        .caret_equal => .bit_xor,
        .shl_equal => .shl,
        .shr_equal => .shr,
        else => null,
    };
}

/// An expression or an assignment, without its `;`.
fn simple(p: *Parser) Error!*Stmt {
    const start = p.current().start;
    const target = try expr.expression(p);
    return finishSimple(p, start, target);
}

/// What follows an expression that may be an assignment's target: the
/// assignment, or else the expression as a statement.
pub fn finishSimple(p: *Parser, start: u32, target: *ast.Expr) Error!*Stmt {
    if (assignOp(p.peek())) |assign| {
        _ = p.advance();
        switch (target.kind) {
            .ident, .field, .index, .self => {},
            .invalid => {},
            else => {
                _ = try (try p.diags.err(p.at(target.span), "this cannot be assigned to", .{}))
                    .text("not a variable, a field or an element", .{});
                return error.Syntax;
            },
        }
        const value = try expr.expression(p);
        return p.new(Stmt, .{ .span = p.spanFrom(start), .kind = .{ .assign = .{ .target = target, .op = assign, .value = value } } });
    }
    return p.new(Stmt, .{ .span = p.spanFrom(start), .kind = .{ .expr = target } });
}

const Branch = struct { stmt: *Stmt, needs_semicolon: bool };

/// The body of an `if`, a loop or a `defer`: a block, or one statement whose
/// `;` may wait for an `else`.
fn branch(p: *Parser) Error!Branch {
    // `if (a) if (b) ...` nests without a block to count it.
    try p.enter();
    defer p.leave();
    switch (p.peek()) {
        .l_brace => {
            const b = try block(p);
            return .{ .stmt = try p.new(Stmt, .{ .span = b.span, .kind = .{ .block = b } }), .needs_semicolon = false };
        },
        .kw_if => return .{ .stmt = try ifStmt(p), .needs_semicolon = false },
        .kw_while => return .{ .stmt = try whileStmt(p, null), .needs_semicolon = false },
        .kw_for => return .{ .stmt = try forStmt(p, null), .needs_semicolon = false },
        .kw_var, .kw_const => return p.fail(Parser.spanOf(p.current()), "a declaration here would be gone at once; put the body in `{{ }}`", .{}),
        else => return .{ .stmt = try simple(p), .needs_semicolon = true },
    }
}

pub fn condition(p: *Parser) Error!*ast.Expr {
    _ = try p.expect(.l_paren, "around the condition");
    const e = try expr.expression(p);
    if (p.check(.equal)) {
        _ = try (try (try p.diags.err(p.at(Parser.spanOf(p.current())), "`=` sets a variable and cannot be a condition", .{}))
            .text("an assignment", .{}))
            .help("to compare, write `==`", .{});
        return error.Syntax;
    }
    _ = try p.expect(.r_paren, "after the condition");
    return e;
}

fn ifStmt(p: *Parser) Error!*Stmt {
    const start = (try p.expect(.kw_if, "")).start;
    const cond = try condition(p);
    const cap = try expr.capture(p);
    const then = try branch(p);
    var else_stmt: ?*Stmt = null;
    var else_cap: ?ast.Name = null;
    var needs_semicolon = then.needs_semicolon;
    if (p.eat(.kw_else)) |_| {
        else_cap = try expr.capture(p);
        const otherwise = try branch(p);
        else_stmt = otherwise.stmt;
        needs_semicolon = otherwise.needs_semicolon;
    }
    if (needs_semicolon) try p.semicolon("after the statement");
    return p.new(Stmt, .{ .span = p.spanFrom(start), .kind = .{ .@"if" = .{ .cond = cond, .capture = cap, .then = then.stmt, .else_capture = else_cap, .@"else" = else_stmt } } });
}

fn loopBody(p: *Parser) Error!*Stmt {
    const body = try branch(p);
    if (body.needs_semicolon) try p.semicolon("after the loop's statement");
    return body.stmt;
}

fn whileStmt(p: *Parser, label: ?ast.Name) Error!*Stmt {
    const start = if (label) |l| l.span.start else p.current().start;
    _ = try p.expect(.kw_while, "");
    const cond = try condition(p);
    const cap = try expr.capture(p);
    var next: ?*Stmt = null;
    if (p.eat(.colon)) |_| {
        _ = try p.expect(.l_paren, "around the step, as in `: (i += 1)`");
        next = try simple(p);
        _ = try p.expect(.r_paren, "after the step");
    }
    const body = try loopBody(p);
    return p.new(Stmt, .{ .span = p.spanFrom(start), .kind = .{ .@"while" = .{ .label = label, .cond = cond, .capture = cap, .next = next, .body = body } } });
}

fn forStmt(p: *Parser, label: ?ast.Name) Error!*Stmt {
    const start = if (label) |l| l.span.start else p.current().start;
    _ = try p.expect(.kw_for, "");
    _ = try p.expect(.l_paren, "around what the loop walks");
    var iterable = try expr.expression(p);
    if (p.check(.dot_dot) or p.check(.dot_dot_equal)) {
        const inclusive = p.advance().kind == .dot_dot_equal;
        const end = try expr.expression(p);
        iterable = try p.new(ast.Expr, .{ .span = iterable.span.to(end.span), .kind = .{ .range = .{ .start = iterable, .end = end, .inclusive = inclusive } } });
    }
    if (p.check(.comma)) {
        return p.fail(Parser.spanOf(p.current()), "a loop walks one thing; the second capture is already the index: `for (items) |item, i|`", .{});
    }
    _ = try p.expect(.r_paren, "after what the loop walks");
    if (!p.check(.pipe)) {
        _ = try (try p.diags.err(p.at(Parser.spanOf(p.current())), "a `for` loop names each item", .{}))
            .help("write `for (items) |item| {{ ... }}`", .{});
        return error.Syntax;
    }
    _ = p.advance();
    const value = try p.expectName("a name for each item");
    var index: ?ast.Name = null;
    if (p.eat(.comma)) |_| index = try p.expectName("a name for the index");
    _ = try p.expect(.pipe, "to close the captures");
    const body = try loopBody(p);
    return p.new(Stmt, .{ .span = p.spanFrom(start), .kind = .{ .@"for" = .{ .label = label, .iterable = iterable, .value = value, .index = index, .body = body } } });
}
