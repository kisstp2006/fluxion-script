/* SPDX-License-Identifier: BSD-2-Clause */

/* Flux from C: load scripts, call into them, give them functions of your
 * own. Link the `fluxion_script` library `zig build` installs.
 *
 *     flux_vm *vm = flux_vm_create();
 *     flux_module *m;
 *     if (flux_load(vm, "main.flux", source, len, &m) != FLUX_OK) {
 *         fprintf(stderr, "%s", flux_error(vm, NULL));
 *     }
 *     flux_value update;
 *     if (flux_get(vm, m, "update", &update) == FLUX_OK) {
 *         flux_value dt = flux_float(1.0 / 60.0), result;
 *         flux_call(vm, update, &dt, 1, &result);
 *     }
 *     flux_vm_destroy(vm);
 *
 * A value is sixteen bytes and passed by value. Numbers, bools and vectors
 * are held in it; strings, lists and objects point into the VM's heap, and
 * stay alive while a script holds them, or while you `flux_hold` them.
 */

#ifndef FLUXION_SCRIPT_H
#define FLUXION_SCRIPT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flux_vm flux_vm;
typedef struct flux_module flux_module;

typedef struct flux_value {
    uint64_t raw;
    uint32_t extra;
    uint32_t tag;
} flux_value;

typedef enum flux_type {
    FLUX_NULL = 0,
    FLUX_BOOL = 1,
    FLUX_INT = 2,
    FLUX_FLOAT = 3,
    FLUX_VEC2 = 4,
    FLUX_VEC3 = 5,
    FLUX_ENUM = 6,
    FLUX_STRING = 8,
    FLUX_LIST = 9,
    FLUX_MAP = 10,
    FLUX_OBJECT = 11,
    FLUX_FUNCTION = 12,
    FLUX_ERROR = 20,
    FLUX_OTHER = 255
} flux_type;

typedef enum flux_status {
    FLUX_OK = 0,
    /* The script did not compile; flux_error() says why. */
    FLUX_COMPILE_ERROR = 1,
    /* The script stopped with a runtime error; flux_error() has the
     * message and the stack trace. */
    FLUX_PANIC = 2,
    FLUX_OUT_OF_MEMORY = 3,
    FLUX_NOT_FOUND = 4,
    /* A script is running: the call must wait until it returns. */
    FLUX_BUSY = 5
} flux_status;

/* -- The virtual machine ------------------------------------------------- */

flux_vm *flux_vm_create(void);
void flux_vm_destroy(flux_vm *vm);

/* Where `print` writes. Without it, printing goes nowhere. */
typedef void (*flux_write_fn)(void *user, const char *bytes, size_t len);
void flux_vm_set_output(flux_vm *vm, flux_write_fn write, void *user);

/* Compiles and runs a module. `name` is what messages call the file. */
flux_status flux_load(flux_vm *vm, const char *name, const char *source, size_t len, flux_module **out);

/* Puts `source` in as a loaded module's new code while the program goes on:
 * whatever holds its functions, structs and instances carries on with the
 * new code, and variables declared as before keep their values. Call it
 * between calls into scripts. FLUX_COMPILE_ERROR leaves everything as it
 * was; FLUX_PANIC means the new code is in but an initializer it ran
 * failed. flux_error() has the errors, or what the reload could not keep. */
flux_status flux_reload(flux_vm *vm, flux_module *module, const char *source, size_t len);

/* The last compile errors or runtime error, as text with a caret under the
 * place and a stack trace; "" when there is none. Valid until the next
 * call into the VM. `len` may be NULL. */
const char *flux_error(flux_vm *vm, size_t *len);

/* A module's variable or function by name. */
flux_status flux_get(flux_vm *vm, flux_module *module, const char *name, flux_value *out);

/* Calls a function with arguments. */
flux_status flux_call(flux_vm *vm, flux_value callee, const flux_value *args, size_t nargs, flux_value *result);

/* Moves script time on by `dt` seconds, waking tasks that `await`ed. */
flux_status flux_update(flux_vm *vm, double dt);

/* Keeps an object alive until as many releases as holds. */
flux_status flux_hold(flux_vm *vm, flux_value v);
void flux_release(flux_vm *vm, flux_value v);

/* -- Functions from C ---------------------------------------------------- */

/* A function scripts can call. Write the result to `*result` and return
 * FLUX_OK, or return flux_fail(vm, "why"). */
typedef flux_status (*flux_native_fn)(flux_vm *vm, const flux_value *args, size_t nargs, flux_value *result, void *user);

/* Every module can call it by `name`. `max_args` -1 takes any number. */
flux_status flux_define(flux_vm *vm, const char *name, flux_native_fn fn, int min_args, int max_args, void *user);

/* For a native: stops the script with `message`. Returns FLUX_PANIC. */
flux_status flux_fail(flux_vm *vm, const char *message);

/* -- Values -------------------------------------------------------------- */

flux_value flux_null(void);
flux_value flux_bool(bool b);
flux_value flux_int(int64_t i);
flux_value flux_float(double f);
flux_value flux_vec2(float x, float y);
flux_value flux_vec3(float x, float y, float z);
/* A string in the VM's heap: hold it, or hand it to the script at once. */
flux_status flux_string(flux_vm *vm, const char *bytes, size_t len, flux_value *out);

flux_type flux_type_of(flux_value v);
bool flux_as_bool(flux_value v);
int64_t flux_as_int(flux_value v);
/* An int or a float, as a double. */
double flux_as_float(flux_value v);
void flux_as_vec2(flux_value v, float out[2]);
void flux_as_vec3(flux_value v, float out[3]);
/* A string's bytes, zero-terminated; NULL for anything else. */
const char *flux_as_string(flux_value v, size_t *len);

size_t flux_list_len(flux_value list);
flux_value flux_list_get(flux_value list, size_t index);
flux_status flux_list_push(flux_vm *vm, flux_value list, flux_value item);

/* A field of a struct instance, or a key of a map, by name. */
flux_status flux_field(flux_vm *vm, flux_value object, const char *name, flux_value *out);
flux_status flux_set_field(flux_vm *vm, flux_value object, const char *name, flux_value v);

/* A value as `print` shows it, in `buffer`; returns the full length. */
size_t flux_to_string(flux_value v, char *buffer, size_t size);

#ifdef __cplusplus
}
#endif

#endif
