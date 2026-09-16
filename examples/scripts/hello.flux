// The smallest program: a constant, a function, an f-string.
//
//     flux run examples/scripts/hello.flux

const name = "world";

fn greet(who: string, times: int = 1) string {
    return f"hello, {who}" + "!".repeat(times);
}

print(greet(name));
print(greet("Flux", 3));
