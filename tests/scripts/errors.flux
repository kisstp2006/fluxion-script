fn parsePort(text: string) !int {
    const n = try int(text);
    if (n < 1 or n > 65535) return error.OutOfRange(f"{n} is not a port");
    return n;
}

print(parsePort("8080") catch 0);
// out: 8080
print(parsePort("abc") catch |e| e.name);
// out: InvalidInt
_ = parsePort("70000") catch |e| print(e, e.message.?);
// out: error.OutOfRange("70000 is not a port") 70000 is not a port

fn steps() !int {
    defer print("defer 1");
    defer print("defer 2");
    errdefer print("errdefer runs");
    print("body");
    return error.Boom;
}
_ = steps() catch |e| print("caught", e);
// out: body
// out: errdefer runs
// out: defer 2
// out: defer 1
// out: caught error.Boom

fn fine() !int {
    errdefer print("not printed");
    defer print("cleanup");
    return 5;
}
print(try fine());
// out: cleanup
// out: 5

fn chain() !string {
    const port = try parsePort("99999");
    return f"port {port}";
}
if (chain()) |text| print(text) else |err| print("chain failed:", err.name);
// out: chain failed: OutOfRange
print(error.NotFound == error.NotFound, error.NotFound == error.Other);
// out: true false

// A function that gives an error or nothing may end without a return.
fn check(ok: bool) !void {
    if (!ok) return error.Refused;
}
check(true) catch |e| print("not printed", e);
check(false) catch |e| print("refused:", e.name);
// out: refused: Refused
