// SPDX-License-Identifier: BSD-2-Clause

//! `flux lsp` in a session an editor could have with it, messages in and
//! out as bytes.

const std = @import("std");
const testing = std.testing;
const json = @import("fluxion_json");

const Server = @import("lsp/Server.zig");
const rpc = @import("lsp/rpc.zig");

const program =
    \\struct Hero {
    \\    var hp: int = 10;
    \\    fn heal(self, amount: int) {
    \\        self.hp += amount;
    \\    }
    \\}
    \\fn main() {
    \\    var h = Hero{};
    \\    h.heal(5);
    \\    h.
    \\}
    \\
;

const doc_uri = "file:///game/hero.flux";

fn frame(gpa: std.mem.Allocator, input: *std.ArrayList(u8), message: anytype) !void {
    const body = try json.stringify(gpa, message, .{});
    defer gpa.free(body);
    try input.print(gpa, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

fn at(id: u32, method: []const u8, line: u32, character: u32) struct {
    jsonrpc: []const u8 = "2.0",
    id: u32,
    method: []const u8,
    params: struct {
        textDocument: struct { uri: []const u8 = doc_uri } = .{},
        position: struct { line: u32, character: u32 },
    },
} {
    return .{ .id = id, .method = method, .params = .{ .position = .{ .line = line, .character = character } } };
}

test "a session: open, ask, change, close" {
    const gpa = testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(gpa);
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .id = 1, .method = "initialize", .params = .{ .capabilities = .{} } });
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .method = "initialized", .params = .{} });
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .method = "textDocument/didOpen", .params = .{ .textDocument = .{ .uri = doc_uri, .languageId = "flux", .version = 1, .text = program } } });
    try frame(gpa, &input, at(2, "textDocument/hover", 8, 6));
    try frame(gpa, &input, at(3, "textDocument/completion", 9, 6));
    try frame(gpa, &input, at(4, "textDocument/definition", 8, 6));
    try frame(gpa, &input, at(5, "textDocument/signatureHelp", 8, 11));
    try frame(gpa, &input, at(6, "textDocument/references", 1, 9));
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .id = 7, .method = "textDocument/semanticTokens/full", .params = .{ .textDocument = .{ .uri = doc_uri } } });
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .id = 8, .method = "textDocument/documentSymbol", .params = .{ .textDocument = .{ .uri = doc_uri } } });
    // The line being typed finished: the mistake goes.
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .method = "textDocument/didChange", .params = .{
        .textDocument = .{ .uri = doc_uri, .version = 2 },
        .contentChanges = &.{.{ .range = .{ .start = .{ .line = 9, .character = 6 }, .end = .{ .line = 9, .character = 6 } }, .text = "hp = 1;" }},
    } });
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .id = 9, .method = "workspace/unknownThing", .params = .{} });
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .method = "textDocument/didClose", .params = .{ .textDocument = .{ .uri = doc_uri } } });
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .id = 10, .method = "shutdown" });
    try frame(gpa, &input, .{ .jsonrpc = "2.0", .method = "exit" });

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var server: Server = .init(gpa, testing.io, &output.writer);
    defer server.deinit();
    var in: std.Io.Reader = .fixed(input.items);
    try testing.expectEqual(@as(u8, 0), try server.run(&in));

    var replies: std.Io.Reader = .fixed(output.written());
    var diagnostics_sent: usize = 0;
    var seen: [11]bool = @splat(false);
    while (try rpc.read(gpa, &replies)) |body| {
        defer gpa.free(body);
        var doc = try json.parse(gpa, body, .{});
        defer doc.deinit();
        const root = doc.root;
        if (root.get("method").asString()) |method| {
            try testing.expectEqualStrings("textDocument/publishDiagnostics", method);
            const list = root.get("params").get("diagnostics");
            // At open, the unfinished `h.`; after the change, nothing; at close, nothing.
            const want: usize = if (diagnostics_sent == 0) 1 else 0;
            testing.expectEqual(want, list.len()) catch |e| {
                std.debug.print("{s}\n", .{body});
                return e;
            };
            if (want == 1) try testing.expectEqual(@as(?u32, 9), list.get(0).get("range").get("start").get("line").asInt(u32));
            diagnostics_sent += 1;
            continue;
        }
        const id = root.get("id").asInt(u32).?;
        seen[id] = true;
        const result = root.get("result");
        switch (id) {
            1 => try testing.expectEqualStrings("utf-16", result.get("capabilities").get("positionEncoding").asString().?),
            2 => try testing.expect(std.mem.indexOf(u8, result.get("contents").get("value").asString().?, "fn Hero.heal(self, amount: int)") != null),
            3 => {
                var labels: std.ArrayList(u8) = .empty;
                defer labels.deinit(gpa);
                for (result.get("items").items()) |item| try labels.print(gpa, "{s} ", .{item.get("label").asString().?});
                try testing.expectEqualStrings("hp heal ", labels.items);
            },
            4 => {
                try testing.expectEqualStrings(doc_uri, result.get("uri").asString().?);
                try testing.expectEqual(@as(?u32, 2), result.get("range").get("start").get("line").asInt(u32));
                try testing.expectEqual(@as(?u32, 7), result.get("range").get("start").get("character").asInt(u32));
            },
            5 => {
                const sig = result.get("signatures").get(0);
                try testing.expectEqualStrings("Hero.heal(amount: int)", sig.get("label").asString().?);
                try testing.expectEqual(@as(?u32, 0), result.get("activeParameter").asInt(u32));
            },
            // `hp` declared, and used in `heal`.
            6 => try testing.expectEqual(@as(usize, 2), result.len()),
            7 => {
                const data = result.get("data");
                try testing.expect(data.len() > 0 and data.len() % 5 == 0);
            },
            8 => {
                try testing.expectEqual(@as(usize, 2), result.len());
                try testing.expectEqualStrings("Hero", result.get(0).get("name").asString().?);
                try testing.expectEqual(@as(usize, 2), result.get(0).get("children").len());
            },
            9 => try testing.expectEqual(@as(?i32, -32601), root.get("error").get("code").asInt(i32)),
            10 => try testing.expect(result == .null),
            else => return error.UnexpectedReply,
        }
    }
    try testing.expectEqual(@as(usize, 3), diagnostics_sent);
    for (seen[1..], 1..) |s, i| if (!s) {
        std.debug.print("no reply to {d}\n", .{i});
        return error.MissingReply;
    };
}
