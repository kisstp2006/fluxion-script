/* SPDX-License-Identifier: BSD-2-Clause */

/* A C program embedding Flux: a function of its own for scripts to call,
 * the script's `update` called every frame, errors shown with their place,
 * and the script reloaded while the program runs.
 *
 *     zig build example-embed-c
 */

#include "fluxion_script.h"

#include <stdio.h>
#include <string.h>

static void write_out(void *user, const char *bytes, size_t len) {
    (void)user;
    fwrite(bytes, 1, len, stdout);
}

/* `spawn_rate(level)`: a function of the program's, called from scripts. */
static flux_status spawn_rate(flux_vm *vm, const flux_value *args, size_t nargs, flux_value *result, void *user) {
    (void)nargs;
    const double base = *(const double *)user;
    if (flux_type_of(args[0]) != FLUX_INT) return flux_fail(vm, "spawn_rate takes a level, as an int");
    *result = flux_float(base * (double)flux_as_int(args[0]));
    return FLUX_OK;
}

static const char script[] =
    "var elapsed = 0.0;\n"
    "var spawned = 0;\n"
    "fn update(dt: float, level: int) {\n"
    "    elapsed += dt;\n"
    "    if (elapsed >= 1.0) {\n"
    "        elapsed -= 1.0;\n"
    "        spawned += int(spawn_rate(level)) catch 0;\n"
    "        print(f\"level {level}: {spawned} spawned\");\n"
    "    }\n"
    "}\n";

/* The same file after an edit: spawns grow faster, and a new variable
 * counts the seconds. `elapsed` and `spawned` keep their values. */
static const char edited[] =
    "var elapsed = 0.0;\n"
    "var spawned = 0;\n"
    "var seconds = 0;\n"
    "fn update(dt: float, level: int) {\n"
    "    elapsed += dt;\n"
    "    if (elapsed >= 1.0) {\n"
    "        elapsed -= 1.0;\n"
    "        seconds += 1;\n"
    "        spawned += (int(spawn_rate(level)) catch 0) * 2;\n"
    "        print(f\"level {level}: {spawned} spawned after {seconds}s of the new code\");\n"
    "    }\n"
    "}\n";

static int run_frames(flux_vm *vm, flux_module *m, int frames, int level) {
    flux_value update;
    if (flux_get(vm, m, "update", &update) != FLUX_OK) return 1;
    for (int i = 0; i < frames; i++) {
        flux_value args[2] = {flux_float(1.0 / 60.0), flux_int(level)};
        if (flux_call(vm, update, args, 2, NULL) != FLUX_OK) {
            fprintf(stderr, "%s", flux_error(vm, NULL));
            return 1;
        }
        flux_update(vm, 1.0 / 60.0);
    }
    return 0;
}

int main(void) {
    flux_vm *vm = flux_vm_create();
    if (!vm) return 1;
    flux_vm_set_output(vm, write_out, NULL);
    double base = 1.5;
    flux_define(vm, "spawn_rate", spawn_rate, 1, 1, &base);

    flux_module *m = NULL;
    if (flux_load(vm, "waves.flux", script, sizeof script - 1, &m) != FLUX_OK) {
        fprintf(stderr, "%s", flux_error(vm, NULL));
        flux_vm_destroy(vm);
        return 1;
    }
    int failed = run_frames(vm, m, 150, 2);

    /* A mistake saved by accident: the reload is refused, the old code runs on. */
    const char *broken =
        "var elapsed = 0.0;\n"
        "var spawned = 0;\n"
        "fn update(dt: float, level: int) { spawned += \"many\"; }\n";
    if (flux_reload(vm, m, broken, strlen(broken)) != FLUX_OK) {
        printf("not reloaded:\n%s", flux_error(vm, NULL));
    }

    if (!failed && flux_reload(vm, m, edited, sizeof edited - 1) == FLUX_OK) {
        printf("reloaded\n");
        failed = run_frames(vm, m, 150, 3);
    }
    flux_vm_destroy(vm);
    return failed;
}
