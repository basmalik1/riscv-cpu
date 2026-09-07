# RISC-V CPU

An RV32I processor built with an entirely open-source flow: Verilator for lint
and simulation, GTKWave for waves, Yosys and sv2v for synthesis, OpenSTA
against the Nangate45 cell library for timing, and Make and Python for glue.

Two cores share the same ports and the same tests — a single-cycle one and a
five-stage pipelined one — so they can be compared directly. There is also a
DE10-Lite FPGA target, simulated but not yet run on hardware. See
[docs/roadmap.md](docs/roadmap.md) for where it goes next.

The layout separates synthesizable RTL from testbench code and keeps each tool
in its own directory, so the pipelined and out-of-order iterations drop in
without moving anything.

```
bin/       toolchain scripts, linker script, C startup code
pkg/       shared SystemVerilog packages
hdl/       synthesizable RTL — common/ plus one directory per core
hvl/       testbench — common/ is simulator-agnostic, unit/ is per-module
lint/      Verilator lint
sim/       build and run the simulation
synth/     Yosys synthesis, area and timing
fpga/      DE10-Lite targets — common/ plus one board top per core
testcode/  test programs
```

## Tools

Everything is open source. Simulation and the whole test suite need only the
first three rows; the last four are for synthesis and timing, which are
optional.

| Tool | Used for | Licence | Install |
|---|---|---|---|
| [Verilator](https://verilator.org) | lint and simulation | LGPL-3.0 / Artistic-2.0 | apt |
| [GTKWave](https://gtkwave.sourceforge.net) | waveforms | GPL-2.0 | apt |
| [RISC-V GCC](https://github.com/riscv-collab/riscv-gnu-toolchain) | assembling and compiling tests | GPL-3.0 | apt |
| [Yosys](https://yosyshq.net/yosys/) | synthesis | ISC | apt |
| [sv2v](https://github.com/zachjs/sv2v) | SystemVerilog to Verilog-2005, in front of Yosys | BSD-3-Clause | binary release |
| [OpenSTA](https://github.com/parallaxsw/OpenSTA) | static timing analysis | GPL-3.0 | source build |
| [Nangate45](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts) | open 45nm standard cell library, for area and timing | see below | `make -C synth pdk` |

`sv2v` is needed because Yosys's built-in frontend rejects any user-defined type
declared at file scope. `OpenSTA` is needed because Yosys's own `sta` command
only understands its internal cell types. Both are explained in
[synth/README.md](synth/README.md), along with the build steps.

**Nangate45** is an open academic cell library distributed with
OpenROAD-flow-scripts, originally from Nangate Inc. via Si2's OpenCell
initiative. It is a teaching and research library, not a fabrication PDK, and
it is used here only as a consistent yardstick for comparing the two cores. It
is downloaded on demand into `synth/pdk/`, which is gitignored — no third-party
library is vendored into this repository.

## Setup

Verilator, GTKWave, Make, and Python you likely already have:

```bash
sudo apt install verilator gtkwave yosys build-essential python3
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

There are two cores. `CORE=` picks one, defaulting to the single-cycle:

```bash
cd sim && make CORE=pipelined run_verilator_top_tb PROG=../testcode/rv32i.s
```

Both expose the same ports, so the testbench and the FPGA top take either. Each
run reports cycles, instructions retired and IPC. Expect the pipelined core to
use *more* cycles on these programs, not fewer — see
[docs/roadmap.md](docs/roadmap.md) for why that is the right answer.

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

Run the per-module unit tests — 181 checks across the ALU, register file,
decoder, hazard unit and all five pipeline stages:

```bash
cd sim && make unit
```

View the waveform:

```bash
cd sim && make waves
```

Synthesise, for cell counts and logic depth. Adding area needs the cell
library, and adding nanoseconds needs OpenSTA on top of that:

```bash
cd synth && make compare        # cells and logic depth
cd synth && make pdk            # fetch Nangate45, 6.4 MB, once
cd synth && make area-compare   # area in um2
cd synth && make timing-compare # critical path in ns
```

`options.json` holds the clock period, timeout, ISA string, and memory map.
Both the Makefiles and `bin/link.ld` read from it, so it is the only place
those numbers live.

## Conventions

- **Halt:** a program ends by executing `slti x0, x0, -256` (`0xf0002013`),
  which the testbench traps to stop the simulation.
- **Memory:** 64 KiB at `0x8000_0000`. The single-cycle core uses
  `hvl/common/magic_memory.sv`, with combinational reads, because it has to
  fetch and access data inside one clock edge. The pipelined core uses
  `hvl/common/sync_memory.sv`, with registered reads, which the pipeline
  registers absorb. `fpga/common/mem_sync.sv` is the synthesizable equivalent.
- **Tests fail loudly:** assembly tests branch to an infinite loop on a
  mismatch, so a failure surfaces as a timeout rather than a quiet pass.

## Status

Both cores execute the full RV32I base integer set and pass the same tests,
retiring identical instruction counts. Verified by a 58-check regression, 181
unit checks, and mutation testing of both — deliberate bugs are injected to
confirm the suites actually catch them.

Measured, on the same programs:

| | single-cycle | pipelined |
|---|---|---|
| IPC | 1.000 | 0.937 |
| cells (Nangate45) | 7193 | 8865 |
| area | 12302 um2 | 15656 um2 |
| logic depth | 44 | 37 |

The pipelined core is slower in cycles and larger in area, which is the
expected result: a scalar pipeline cannot beat IPC 1.0, and the win is clock
period rather than cycle count.

Two things are honestly still open. The clock-period claim rests on logic depth
rather than nanoseconds — the timing flow runs, but without a buffering and
resizing pass its numbers are dominated by unbuffered high-fanout nets, so they
are not a fair comparison. And the FPGA target is simulated only; pin
assignments and timing closure are unverified. Both are written up where they
belong, in [synth/README.md](synth/README.md) and [fpga/README.md](fpga/README.md).
