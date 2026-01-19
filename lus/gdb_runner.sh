#!/bin/bash
# Run the test under GDB in batch mode
# We use "$@" to pass the executable and arguments provided by Meson
output=$(gdb -batch -ex "run" -ex "bt" --args "$@" 2>&1)
if echo "$output" | grep -q "Program received signal"; then
    echo "$output"
    exit 1
fi
exit 0