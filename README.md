# RISC-V CPU

An RV32I processor built with an entirely open-source flow — Verilator for lint
and simulation, GTKWave for waves, Make and Python for glue. Currently a
single-cycle core; see [docs/roadmap.md](docs/roadmap.md) for where it goes
from here.

The layout separates synthesizable RTL from testbench code and keeps each tool
in its own directory, so the pipelined and out-of-order iterations drop in
without moving anything.

```
bin/       toolchain scripts, linker script, C startup code
pkg/       shared SystemVerilog package (types.sv)
hdl/       synthesizable RTL
hvl/       testbench — common/ is simulator-agnostic, verilator/ is the front end
lint/      Verilator lint
sim/       build and run the simulation
testcode/  assembly tests
```

## Setup

Everything runs in WSL2 / Ubuntu. Verilator, GTKWave, Make, and Python you
likely already have:

```bash
sudo apt install verilator gtkwave build-essential python3
```

The RISC-V cross compiler is the one piece that needs care:

```bash
sudo apt install gcc-riscv64-unknown-elf
```

Confirm it can target 32-bit:

```bash
riscv64-unknown-elf-gcc -print-multi-lib | grep rv32i/ilp32
```

On Ubuntu 24.04 that package ships the `rv32i/ilp32` multilib but **no C
library** — no newlib `libc.a`, no `libgloss.a`, only `libgcc.a`. Programs are
therefore built freestanding (`-nostdlib -lgcc`), which is what
`bin/generate_memory_file.py` does. In practice that means:

- `libgcc` helpers are available, so C code can multiply and divide on RV32I
  even though the hardware has no M extension.
- There is no `printf`, `malloc`, `memcpy`, or `memset`. GCC can emit implicit
  calls to `memcpy`/`memset` for large struct or array initialisers; if you hit
  an undefined reference, supply your own.

If you want a full C library, build a toolchain with newlib from
[riscv-collab](https://github.com/riscv-collab/riscv-gnu-toolchain) or install
an xPack release, then point `GCC` in `bin/generate_memory_file.py` at it.

## Usage

Lint the RTL:

```bash
cd lint && make
```

Build and run a test:

```bash
cd sim && make run_verilator_top_tb PROG=../testcode/rv32i.s   # full ISA
cd sim && make run_verilator_top_tb PROG=../testcode/smoke.s   # quick check
cd sim && make run_verilator_top_tb PROG=../testcode/ctest.c   # C toolchain
```

`PROG` takes a `.s`, a `.c`, or a prebuilt `.elf`. Assembly tests define their
own `_start` and are linked without `bin/startup.s`; C tests get it, so
`ctest.c` is what keeps the startup code and linker script honest.

`rv32i.s` is the real regression: 58 checks covering every instruction in the
base integer set, including each byte and halfword offset for loads and stores
and both directions of every branch. A failure spins in place with the failing
check number left in `t0`, so the waveform tells you which one broke without
bisecting. The final guard compares a running count against the assembler's own
tally, so a check that never executed fails too.

Memory not covered by the program image — `.bss`, the stack, any gap — is left
at zero by default, which means a read of never-initialised memory looks
plausible instead of wrong. To make those reads visible, poison the gaps:

```bash
cd sim && make run_verilator_top_tb PROG=../testcode/ctest.c MEM_FILL=deadbeef
```

Worth knowing before you rely on it: a poison word like `deadbeef` has `0x6f` in
its low byte, which is the `JAL` opcode, so a runaway fetch into a poisoned gap
jumps rather than faulting. Zero is the safer default for exactly that reason —
all-zero is a defined illegal instruction.

View the waveform:

```bash
cd sim && make waves
```

`options.json` holds the clock period, timeout, ISA string, and memory map.
Both the Makefiles and `bin/link.ld` read from it, so it is the only place
those numbers live.

## Conventions

- **Halt:** a program ends by executing `slti x0, x0, -256` (`0xf0002013`),
  which the testbench traps to stop the simulation.
- **Memory:** 64 KiB at `0x8000_0000`, modelled by `hvl/common/magic_memory.sv`
  with combinational reads and clocked writes.
- **Tests fail loudly:** assembly tests branch to an infinite loop on a
  mismatch, so a failure surfaces as a timeout rather than a quiet pass.

## Status

The harness, memory model, ALU, and register file are complete. The datapath in
`hdl/cpu.sv` and the decoder in `hdl/control.sv` are stubs — every `TODO` in
those two files is a piece of the single-cycle core still to build.
