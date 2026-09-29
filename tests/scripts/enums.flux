enum State { idle, run, jump = 10, dead }

enum Dir {
    left,
    right,

    fn flip(self) Dir {
        return switch (self) {
            .left => .right,
            .right => .left,
        };
    }
}

var state: State = .idle;
print(state, State.run, int(State.jump), int(State.dead));
// out: State.idle State.run 10 11
state = .run;
const moving = switch (state) {
    .idle, .dead => false,
    .run, .jump => true,
};
print(moving, state == .run, state != State.idle);
// out: true true true
print(Dir.left.flip(), Dir.right.flip().flip());
// out: Dir.right Dir.right
const states: [State] = [.idle, .dead];
print(states);
// out: [State.idle, State.dead]
const names: [State: string] = {.idle: "resting", .run: "running"};
print(names[.run], names.get(.jump) orelse "?");
// out: running ?
print(State.members(), State.members().len);
// out: [State.idle, State.run, State.jump, State.dead] 4
print(state.name(), Dir.left.flip().name());
// out: run right
const found: ?State = State.from_name("jump");
print(found, State.from_name("fly"), State.from_int(11), State.from_int(3));
// out: State.jump null State.dead null
for (Dir.members()) |d| print(d.name(), int(d));
// out: left 0
// out: right 1
const all: [State] = State.members();
print(all.map(fn(s: State) string { return s.name(); }).join(","));
// out: idle,run,jump,dead
