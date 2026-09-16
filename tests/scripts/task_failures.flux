fn boom() int {
    await wait(0.5);
    panic("the fuse blew");
}

fn watcher(t: task) {
    const r = await t;
    print("never", r);
}

fn late(t: task) {
    await wait(2.0);
    const r = await t;
    print("never either", r);
}

const t = boom();
watcher(t);
late(t);
print("started");
// out: started
// task panic: the awaited task failed: the fuse blew
// task panic: the awaited task failed: the fuse blew
