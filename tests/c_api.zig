// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const flux = @import("fluxion_script");

comptime {
    _ = flux.c;
}

extern fn fxs_c_api_test() c_int;

test "the C API, from C" {
    try std.testing.expectEqual(@as(c_int, 0), fxs_c_api_test());
}
