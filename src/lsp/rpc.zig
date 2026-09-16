// SPDX-License-Identifier: BSD-2-Clause

//! JSON-RPC as the Language Server Protocol frames it: a `Content-Length`
//! header, a blank line, and that many bytes of JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ReadError = error{ ReadFailed, StreamTooLong, EndOfStream, OutOfMemory, NoLength };

/// The next message's body, or null when the input has ended.
pub fn read(gpa: Allocator, in: *std.Io.Reader) ReadError!?[]u8 {
    var length: ?usize = null;
    var any = false;
    while (true) {
        const line = (try in.takeDelimiter('\n')) orelse return if (any) error.EndOfStream else null;
        any = true;
        const header = std.mem.trimEnd(u8, line, "\r");
        if (header.len == 0) break;
        const name = "content-length:";
        if (header.len > name.len and std.ascii.eqlIgnoreCase(header[0..name.len], name)) {
            length = std.fmt.parseInt(usize, std.mem.trim(u8, header[name.len..], " \t"), 10) catch null;
        }
    }
    return try in.readAlloc(gpa, length orelse return error.NoLength);
}

pub fn write(out: *std.Io.Writer, body: []const u8) std.Io.Writer.Error!void {
    try out.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try out.writeAll(body);
    try out.flush();
}

test "messages are read by their length" {
    var in: std.Io.Reader = .fixed("Content-Length: 2\r\nContent-Type: x\r\n\r\n{}Content-Length: 4\r\n\r\nnull");
    const first = (try read(std.testing.allocator, &in)).?;
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{}", first);
    const second = (try read(std.testing.allocator, &in)).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("null", second);
    try std.testing.expectEqual(@as(?[]u8, null), try read(std.testing.allocator, &in));
}
