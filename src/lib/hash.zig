// SPDX-License-Identifier: BSD-2-Clause

//! `const hash = @import("hash");`: digests of text, as lowercase hex - what
//! a web API signs its requests with.

const std = @import("std");
const crypto = std.crypto;

const Vm = @import("../vm/Vm.zig");
const Value = @import("../vm/value.zig").Value;
const make = @import("../vm/make.zig");
const native = @import("native.zig");
const Error = native.Error;

pub fn install(vm: *Vm) std.mem.Allocator.Error!void {
    const m = try make.module(vm, try vm.intern("hash"));
    try vm.native_modules.put(vm.gpa, try vm.gpa.dupe(u8, "hash"), m);
    m.state = .ready;
    try native.function(vm, m, "md5", digestOf(crypto.hash.Md5), 1, 1);
    try native.function(vm, m, "sha1", digestOf(crypto.hash.Sha1), 1, 1);
    try native.function(vm, m, "sha256", digestOf(crypto.hash.sha2.Sha256), 1, 1);
    try native.function(vm, m, "hmac_sha256", hmacSha256, 2, 2);
}

fn digestOf(comptime H: type) native.Fn {
    return struct {
        fn digest(vm: *Vm, args: []Value) Error!Value {
            var out: [H.digest_length]u8 = undefined;
            H.hash(try native.bytes(vm, args, 0), &out, .{});
            return hex(vm, &out);
        }
    }.digest;
}

fn hmacSha256(vm: *Vm, args: []Value) Error!Value {
    const Hmac = crypto.auth.hmac.sha2.HmacSha256;
    var out: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&out, try native.bytes(vm, args, 1), try native.bytes(vm, args, 0));
    return hex(vm, &out);
}

fn hex(vm: *Vm, digest: []const u8) Error!Value {
    var text: [128]u8 = undefined;
    const written = std.fmt.bufPrint(&text, "{x}", .{digest}) catch unreachable;
    return vm.string(written);
}
