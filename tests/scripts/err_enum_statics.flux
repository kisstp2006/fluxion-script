enum State { idle, run }
const s: State = State.from_name("run");
// error: may be null
State.members().push(1);
// error: argument
print(State.walk());
// error: `State` has no member `walk`
print(State.idle.title());
// error: `State` has no method `title`
