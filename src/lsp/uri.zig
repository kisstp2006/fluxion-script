// SPDX-License-Identifier: BSD-2-Clause

//! `file://` URIs, as an editor names a document, and the paths the
//! compiler and the loader use. On Windows a URI's path starts with its
//! drive, `file:///c%3A/game/main.flux`, and the path with no slash before
//! it: `c:/game/main.flux`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const prefix = "file://";

/// The path a URI names; a URI that is not a file's names itself.
pub fn toPath(gpa: Allocator, uri: []const u8) Allocator.Error![]u8 {
    if (!std.mem.startsWith(u8, uri, prefix)) return gpa.dupe(u8, uri);
    const encoded = uri[prefix.len..];
    var out: std.ArrayList(u8) = try .initCapacity(gpa, encoded.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            if (std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16)) |byte| {
                out.appendAssumeCapacity(byte);
                i += 2;
                continue;
            } else |_| {}
        }
        out.appendAssumeCapacity(encoded[i]);
    }
    // `/c:/game` is `c:/game`.
    if (out.items.len >= 3 and out.items[0] == '/' and std.ascii.isAlphabetic(out.items[1]) and out.items[2] == ':') {
        _ = out.orderedRemove(0);
    }
    return out.toOwnedSlice(gpa);
}

/// The URI of a path.
pub fn fromPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, prefix);
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') try out.append(gpa, '/');
    for (path) |c| {
        const byte = if (c == '\\') '/' else c;
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~:", byte) != null) {
            try out.append(gpa, byte);
        } else {
            try out.print(gpa, "%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Whether two paths name the same file: slashes either way, and on
/// Windows letters in either case.
pub fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const p = if (x == '\\') '/' else x;
        const q = if (y == '\\') '/' else y;
        if (builtin.os.tag == .windows) {
            if (std.ascii.toLower(p) != std.ascii.toLower(q)) return false;
        } else if (p != q) return false;
    }
    return true;
}

test "a URI and its path, both ways" {
    const gpa = std.testing.allocator;
    const path = try toPath(gpa, "file:///c%3A/My%20Game/main.flux");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("c:/My Game/main.flux", path);
    const unix = try toPath(gpa, "file:///home/ada/game/main.flux");
    defer gpa.free(unix);
    try std.testing.expectEqualStrings("/home/ada/game/main.flux", unix);
    const back = try fromPath(gpa, "c:\\My Game\\main.flux");
    defer gpa.free(back);
    try std.testing.expectEqualStrings("file:///c:/My%20Game/main.flux", back);
    try std.testing.expect(samePath("c:/game/a.flux", "c:\\game\\a.flux"));
}
