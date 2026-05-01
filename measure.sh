#!/bin/bash
# Rebuild + measure cycles across both prescales for optimization work.
cd "$(dirname "$0")"
./beebasm -i doom_fe.asm -o doom_fe.bin > /dev/null 2>&1 || { echo "BUILD FAIL"; exit 1; }

DOOM_PRESCALE=8 python3 verify_exact.py 2>&1 | grep -E "6502-cyc|ALL|DIVERGE" | head -8
echo "---"
DOOM_PRESCALE=16 python3 verify_exact.py 2>&1 | grep -E "6502-cyc|ALL|DIVERGE" | head -8
