# RISC-V CPU

An RV32IM processor built with an entirely open-source flow: Verilator for lint
and simulation, Spike as the golden model, GTKWave for waves, Yosys and sv2v
for synthesis, OpenSTA against the Nangate45 cell library for timing, and Make
and Python for glue.

Two cores share the same ports and the same tests — a single-cycle one and a
five-stage pipelined one — so they can be compared directly. Both implement the
base integer set and the M extension; the multiply/divide unit is one module
parameterised by whether its divider is combinational or iterative, which is
where the two designs differ most sharply. There is also a
DE10-Lite FPGA target, simulated but not yet run on hardware. See
[docs/roadmap.md](docs/roadmap.md) for where it goes next.

The layout separates synthesizable RTL from testbench code and keeps each tool
in its own directory, so each new core drops in beside the last rather than
replacing it. The pipelined one did; the out-of-order one is being built the
same way.

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

Everything is open source. Simulation and the self-checking tests need only the
first three rows; Spike adds golden-model lockstep, and the last four are for
synthesis and timing. Everything after the third row is optional.

| Tool | Used for | Licence | Install |
|---|---|---|---|
| [Verilator](https://verilator.org) | lint and simulation | LGPL-3.0 / Artistic-2.0 | apt |
| [GTKWave](https://gtkwave.sourceforge.net) | waveforms | GPL-2.0 | apt |
| [RISC-V GCC](https://github.com/riscv-collab/riscv-gnu-toolchain) | assembling and compiling tests | GPL-3.0 | apt |
| [Spike](https://github.com/riscv-software-src/riscv-isa-sim) | reference model, for lockstep | BSD-3-Clause | source build |
| [Yosys](https://yosyshq.net/yosys/) | synthesis | ISC | apt |
| [sv2v](https://github.com/zachjs/sv2v) | SystemVerilog to Verilog-2005, in front of Yosys | BSD-3-Clause | binary release |
| [OpenSTA](https://github.com/parallaxsw/OpenSTA) | static timing analysis | GPL-3.0 | source build |
| [Nangate45](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts) | open 45nm standard cell library, for area and timing | see below | `make -C synth pdk` |

`Spike` is the RISC-V reference simulator, and every instruction the core
retires is checked against it — see [docs/spike.md](docs/spike.md) for the build
and for what is and is not compared.

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

- `libgcc` helpers are available, though with `arch` set to `rv32im` in
  `options.json` the compiler emits hardware `mul`/`div` instead of calling
  them. Set it back to `rv32i` to exercise the software path.
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
cd sim && make run_verilator_top_tb PROG=../testcode/rv32i.s   # base integer set
cd sim && make run_verilator_top_tb PROG=../testcode/rv32m.s   # multiply/divide
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

`rv32i.s` is the real regression: 66 checks covering every instruction in the
base integer set, including each byte and halfword offset for loads and stores
and both directions of every branch. `rv32m.s` adds 60 more for the M
extension — every multiply and divide, the values the spec fixes by decree
(divide by zero, signed overflow, which way truncation goes), and the pipeline
interactions a 34-cycle instruction creates. A failure spins in place with the
failing check number left in `t0`, so the waveform tells you which one broke
without bisecting. The final guard compares a running count against the
assembler's own tally, so a check that never executed fails too.

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

Run the unit tests — 22712 checks across twenty testbenches: the ALU,
register file, decoder, hazard unit, multiply/divide unit, all five pipeline
stages, a cycle-level harness for the assembled pipeline, and the out-of-order
structures built so far:

```bash
cd sim && make unit
```

Confirm those tests can actually fail:

```bash
cd sim && make mutate             # every module that has cases
cd sim && make mutate MODULE=rat  # just one
```

A passing test proves nothing on its own — it might be checking the right
thing, or nothing at all, and the two look identical from outside. So every
claim this repo makes about a testbench is backed by injecting bugs into the
module and confirming the test goes red. `bin/mutations.json` holds the bugs;
`bin/mutate.py` runs them and exits non-zero unless every one is caught.

It reports a mutation that failed to build, or that hung, as neither a pass nor
a catch. Both say nothing about the test, and an earlier version of this scored
them as though they did.

Check every retired instruction against Spike, and the two cores against each
other:

```bash
cd sim && make lockstep   PROG=../testcode/rv32i.s   # core vs the golden model
cd sim && make crosscheck PROG=../testcode/rv32i.s   # core vs core, no Spike needed
```

`crosscheck` needs no Spike and is worth reaching for first when something
breaks: the two microarchitectures share only the decoder, the ALU and the
multiply/divide unit, so it says immediately whether a bug is in the shared
logic or in one core's control. See [docs/spike.md](docs/spike.md).

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

Both cores execute the full RV32I base integer set and the M extension, pass
the same tests, and produce byte-identical commit traces. Verified at four
levels: every retired instruction checked against Spike, a 126-check ISA
regression across two programs, 22712 unit checks including a cycle-level
pipeline harness, and mutation testing of all of it — deliberate bugs are
injected to confirm the suites can actually fail.

Each layer catches something the others cannot, and there is evidence for that
rather than an assumption:

- **Lockstep** removes the need for an assertion to exist. Delete the eight
  `mulh` checks from `rv32m.s` and break `mulh`, and the program passes while
  Spike catches it. `rv32i.s` executes 471 instructions and asserts on 66; the
  other 405 are checked by nothing else.
- **The cycle-level harness** catches timing, which Spike has no notion of.
  Failing to bubble EX/MEM during a divide retires 33 phantom instructions per
  divide, each writing a partial quotient to a register nothing reads yet —
  every program still gets the right answer, and every commit log still matches.
- **Unit tests** reach inputs no program produces. A `srl` that ignores the
  5-bit shift mask needs a shift of 32 to show, and nothing shifts that far.
- **Programs** are the end-to-end check that the parts add up.

Measured:

| | single-cycle | pipelined |
|---|---|---|
| IPC, `rv32i.s` | 1.000 | 0.917 |
| IPC, `rv32m.s` | 1.000 | 0.216 |
| cells (Nangate45) | 18078 | 18553 |
| area | 25019 um2 | 26570 um2 |
| logic depth | 498 | 58 |
| critical path | 27.172 ns | 4.587 ns |

**Adding M is what made the clock-period argument measurable.** Before it the
two critical paths were 4.432 ns and 4.140 ns — a 7% difference, and this flow
is not accurate enough to support a 7% claim. A combinational divider is 21 ns
by itself, so the single-cycle core now sits at 27.2 ns against the pipelined
core's 4.6 ns: **about 6x**, corroborated independently by logic depth at 8.6x.
Not more precisely than that — repeated runs of the same flow on the same
design put the ratio between 5.9x and 6.0x, because ABC's heuristics shift by a
percent or two whenever the netlist changes. Quoting three decimals would imply
a reproducibility this flow does not have.

The gap is far too large for the flow's known inaccuracy to explain, and the
inaccuracy runs the wrong way to help — 71% of the pipelined path is a single
unbuffered mux, so its true path is *shorter* than measured and 6x is a floor.
The single-cycle path, by contrast, spreads 27.2 ns over 503 cells with no gate
above 0.5 ns, which is what a real ripple through a divider looks like.

The honest counterweight is `rv32m.s` itself, where the pipelined core is
**slower in wall-clock time on the board**: 36.6 us against 31.8 us. A
restoring divider costs 33 cycles, and that program is 11% divides — which is
pathological for real code, and exactly the case a one-bit-per-cycle divider
handles worst. Radix-4 would halve it. Nothing here does that yet.

Two things are still open. The FPGA target is simulated only; pin assignments
and timing closure are unverified. And the commit trace reports the store an
instruction *intended* — effective address, data and width — but not the byte
lane shifting downstream of it, so that last class of store bug still reports
at the load that observes the damage rather than at the store. Both are written
up where they belong, in [synth/README.md](synth/README.md),
[fpga/README.md](fpga/README.md) and [docs/spike.md](docs/spike.md).
