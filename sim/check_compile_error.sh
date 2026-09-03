#!/bin/bash

set -e

LOG=verilator/build/compile.log

if [ ! -f "$LOG" ] || grep -q '%Error' "$LOG"; then
    echo -e "\033[0;31mCompile failed \033[0m"
    exit 1
fi

if grep -q '%Warning' "$LOG"; then
    echo -e "\033[0;33mCompile finished with warnings \033[0m"
    exit 69
fi

echo -e "\033[0;32mCompile Successful \033[0m"
exit 0
