# Roadmap

Four iterations, each one a working CPU before the next starts.

## 1. Single-cycle RV32I — *done, tagged v1.0*

One instruction per cycle, zero-latency memory, no hazards to speak of.

**Done when:** every instruction in the RV32I base set executes correctly and
the tests in `testcode/` reach the halt instruction instead of their fail loop.

Remaining work is all inside `hdl/cpu.sv` and `hdl/control.sv` — every `TODO`
in those two files is a piece of the datapath.

## 2. Pipelined — *current*

Classic five stages (IF / ID / EX / MEM / WB) with forwarding and stalls.
Lives in `hdl/pipelined/`; `make CORE=pipelined` selects it, and the
single-cycle core stays in the tree so the two can be compared directly.

**Done when:** the same `testcode/` suite passes on both cores, retiring the
same number of instructions, and the pipelined core runs meaningfully faster
in wall-clock time on the same board.

The first two hold. The third is measured at roughly 3.1x to 3.75x in
simulation (see the FPGA section below), but rests on the pipelined core
closing timing at 50 MHz, which is still unverified.

### A correction to the criterion this originally had

It used to say "IPC measurably better than the single-cycle design". That is
not achievable, and the mistake is worth keeping visible. The single-cycle
core retires exactly one instruction per cycle by construction, so its IPC is
1.000 and no scalar pipeline can beat it. Pipeline fill, the two-cycle
penalty on a taken branch, and load-use stalls only ever push IPC below 1.

Measured, once both cores were passing:

| Test | single-cycle | pipelined | retired |
|---|---|---|---|
| `rv32i.s` | 436 cycles, IPC 1.000 | 465 cycles, IPC 0.937 | 436 both |
| `ctest.c` | 212 cycles, IPC 1.000 | 274 cycles, IPC 0.773 | 212 both |
| `smoke.s` | 22 cycles, IPC 1.000 | 29 cycles, IPC 0.758 | 22 both |

The pipelined core is *slower in cycles* on every test, and that is the
expected result. The win is entirely in clock period: the single-cycle
critical path runs fetch through decode, register read, ALU, memory and
writeback in one cycle, while the pipelined one is bounded by its longest
single stage. Cycles per program is the wrong axis; cycles multiplied by
clock period is the right one, and that number needs synthesis to obtain.

The matching retired counts are the useful correctness signal here: both
cores do exactly the same work on every test.

### This is also the natural moment to target an FPGA (DE10-Lite, MAX 10)

Going to synchronous-read memory is what unblocks hardware, so the port stops
being a workaround and becomes the shape the design already wants.

Why it cannot happen in iteration 1: MAX 10 embedded memory is M9K blocks, whose
output is registered. The architecture is LE-based with no MLAB/distributed RAM,
so there is no LUT-RAM fallback and a combinational-read array has to become
flip-flops. The 64 KiB image is 512 Kbit — comfortably inside the 10M50's
~1,638 Kbit of M9K if the read is synchronous, but roughly 524,000 registers
against ~50K logic elements if it is not. Capacity is fine; read timing is the
blocker. (The usual single-cycle workaround, clocking memory on the negative
edge so the read lands mid-cycle, works and is what most lab courses do. It is
timing-fragile and caps fmax — a demo, not a design.)

What a port needs beyond the memory:

- An `fpga/` top level: 50 MHz clock, `KEY0` as active-low reset, pin assignments.
- A `.mif` / Intel `.hex` output mode in `bin/generate_memory_file.py` for memory
  initialisation. The section-walking logic it needs is already there.
- Observability: there is no `printf`, so halt and error go to LEDs and a
  register value to the 7-segment displays.

### Measured, once the pipelined board top existed

The single-cycle board top divides the 50 MHz board clock by four, because
one instruction needs two memory edges. The pipelined one does not: IF and
MEM hold different instructions, so both memory ports are enabled every
cycle and the core runs directly at 50 MHz with no derived clock at all.

Same programs, same board clock, in simulation:

| Test | single-cycle | pipelined | speedup |
|---|---|---|---|
| `rv32i.s` | 1748 board cycles, 34.96 us | 466, 9.32 us | **3.75x** |
| `ctest.c` | 852 board cycles, 17.04 us | 275, 5.50 us | **3.10x** |
| `smoke.s` | 92 board cycles, 1.84 us | 30, 0.60 us | **3.07x** |

This is the iteration 2 win, and note where it comes from: the pipelined
core has *worse* IPC and uses more of its own cycles. It wins purely on
clock rate. Wall-clock time is the axis that matters, not cycle count.

It assumes the pipelined core closes timing at 50 MHz, which only the fitter
can confirm. The single-cycle figure is on firmer ground, 12.5 MHz being
slack-rich by construction.

**Toolchain caveat.** This needs Quartus Prime Lite, which is free but
proprietary. Yosys/nextpnr do not target MAX 10, so there is no open-source
route to this board — the "entirely open-source flow" claim in the README holds
for simulation and stops holding at the bitstream.

## 3. Out-of-order

Tomasulo-style: register rename, reservation stations, a reorder buffer,
in-order commit.

New: `hdl/` grows the rename/dispatch/ROB/RS modules, and `hvl/` needs a real
commit-log monitor to keep the verification honest.

**Done when:** CoreMark runs to completion and commits match the golden model
instruction for instruction.

## 4. Advanced features

Caches, branch prediction, superscalar issue, a multiply/divide unit — picked
based on what the IPC numbers say is actually the bottleneck.

## Memory model per iteration

Each iteration gets the simplest memory that makes its hazards real. Reaching
for a realistic model early just adds noise to debug through: a memory that can
stall or reorder is only worth modelling once the core can do something about
it.

| Model | Read latency | Iteration | What it makes real |
|---|---|---|---|
| Combinational / "magic" | 0 | 1 — single-cycle | nothing; anything slower breaks the one-cycle contract |
| Synchronous read (true BRAM) | 1, fixed | 2 — pipelined | load-use hazards, IF/MEM stage stalls |
| Variable latency + `resp` handshake | variable | 3 — out-of-order | something worth reordering around |
| Burst SDRAM + FR-FCFS | long, reordered | 4 — advanced | what caches and prefetch get measured against |

Two consequences worth remembering:

- A synchronous read is not an option in iteration 1. It forces either 2 cycles
  per instruction or a negedge-clocked memory hack, and neither is a
  single-cycle design any more.
- The `resp` handshake is deliberately *not* pre-built. The pipelined iteration
  rewrites `hdl/cpu.sv` wholesale, so adding it now buys nothing.

---

## Infrastructure deferred until it is needed

- **Spike lockstep.** RVFI-style commit ports on `cpu.sv` plus a Python
  comparator against `spike --log-commits`. Self-checking assembly is enough
  through iteration 1; this becomes necessary around iteration 2 and
  indispensable at iteration 3. The memory base is already `0x8000_0000` —
  Spike's default — so nothing needs remapping when it lands.
- **Yosys synthesis** in a `synth/` directory, for cell count and timing
  feedback. Worth adding once the pipelined design needs a clock-period
  argument. Blocked as written: Yosys 0.33's built-in frontend has no
  SystemVerilog package support, so it rejects both `module m import p::*;` and
  a body-level `import p::*;`. Verilator and Quartus both accept them, so this
  is a Yosys limitation, not an RTL one — it needs `sv2v` in front, or a
  Verific-enabled build.
- **CI**, once there is a test suite worth regressing.
