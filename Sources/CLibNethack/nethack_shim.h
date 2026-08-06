#pragma once
#include <stdarg.h>

// Public API for NetHack's libnh library.
// There is no official header; see vendor/NetHack/sys/libnh/README.md.
//
// Callback type for window/graphics events dispatched by NetHack.
//   name:    the window function being called (see vendor/NetHack/doc/window.txt)
//   ret_ptr: storage for the return value; type is described by fmt[0]
//   fmt:     type-signature string — first char is the return type, remaining
//            chars are argument types: 'i' int, 's' string, 'p' pointer,
//            'c' char, 'v' void
typedef void(*shim_callback_t)(const char *name, void *ret_ptr, const char *fmt, ...);

// Register the graphics/window callback. Call this before nhmain().
extern void shim_graphics_set_callback(shim_callback_t cb);

// Run NetHack. Blocks until the game ends.
// argc/argv are the standard command-line arguments.
extern int nhmain(int argc, char *argv[]);
