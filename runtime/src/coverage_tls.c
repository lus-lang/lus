// The stack depth variable that LLVM's coverage instrumentation refers to.
// It lives in a C file because the instrumented Zig code declares it
// itself, and a Zig definition in the same unit would clash with that
// declaration. `coverage.zig` holds the rest of the coverage support.
#include <stdint.h>

__thread uintptr_t __sancov_lowest_stack;
