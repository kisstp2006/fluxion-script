// A coroutine and a plain function of the same shape are not one type:
// calling the coroutine without `await` gives its task.
fn step() {}

fn looping() {
    await wait(1.0);
    step();
    print("looped");
}

fn twice(n: int) int {
    await wait(0.5);
    return n * 2;
}

fn plain(n: int) int {
    return n * 2;
}

const t = looping();
print(typeof(t));
const u = twice(4);
print(typeof(u), plain(4));

fn later() {
    print("twice gave", await u);
}
later();
// out: task
// out: task 8
// out: twice gave 8
// out: looped
