# Roadmap

Four iterations, each one a working CPU before the next starts.

## 1. Single-cycle RV32I — *done, tagged v1.0*

One instruction per cycle, zero-latency memory, no hazards to speak of.

**Done when:** every instruction in the RV32I base set executes correctly and
the tests in `testcode/` reach the halt instruction instead of their fail loop.

## 2. Pipelined — *done, tagged v2.0*

Classic five stages (IF / ID / EX / MEM / WB) with forwarding and stalls.
Lives in `hdl/pipelined/`; `make CORE=pipelined` selects it, and the
single-cycle core stays in the tree so the two can be compared directly.

**Done when:** the same `testcode/` suite passes on both cores, retiring the
same number of instructions, and the pipelined core runs meaningfully faster
in wall-clock time on the same board.

The first two hold. The third is measured at 3.07x to 3.67x in simulation on
integer code (see the FPGA section below), and rests on the pipelined core
closing timing at 50 MHz, which only the fitter can confirm.

### A correction to the criterion this originally had

It used to say "IPC measurably better than the single-cycle design". That is
not achievable, and the mistake is worth keeping visible. The single-cycle
core retires exactly one instruction per cycle by construction, so its IPC is
1.000 and no scalar pipeline can beat it. Pipeline fill, the two-cycle
penalty on a taken branch, and load-use stalls only ever push IPC below 1.

Measured, once both cores were passing:

| Test | single-cycle | pipelined | retired |
|---|---|---|---|
| `rv32i.s` | 470 cycles, IPC 1.000 | 512 cycles, IPC 0.917 | 470 both |
| `rv32m.s` | 396 cycles, IPC 1.000 | 1828 cycles, IPC 0.216 | 396 both |
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
| `rv32i.s` | 1884 board cycles, 37.68 us | 513, 10.26 us | **3.67x** |
| `ctest.c` | 852 board cycles, 17.04 us | 275, 5.50 us | **3.10x** |
| `smoke.s` | 92 board cycles, 1.84 us | 30, 0.60 us | **3.07x** |
| `rv32m.s` | 1588 board cycles, 31.76 us | 1829, 36.58 us | **0.87x** |

This is the iteration 2 win, and note where it comes from: the pipelined
core has *worse* IPC and uses more of its own cycles. It wins purely on
clock rate. Wall-clock time is the axis that matters, not cycle count.

`rv32m.s` is the exception and it is not an artifact. That program is 11%
divides, each costing the pipelined core 33 stall cycles, while a fixed 12.5
MHz board clock never charges the single-cycle core for the 27 ns critical path
its combinational divider creates. Both halves of that are honest: a
one-bit-per-cycle divider really is slow, and the board really does undercharge
the single-cycle core. See `synth/README.md`.

**These numbers were wrong once, and the reason is worth recording.** `sim/`
built both board tops into one `fpga/build/` directory, so `make CORE=pipelined
run_fpga_sim` found a binary newer than its sources, skipped the rebuild, and
ran the single-cycle core while reporting entirely plausible figures. The same
bug had already been found and fixed on the simulation path (`VDIR :=
verilator/$(CORE)`) without anyone noticing the FPGA path did it too. Both are
now per-core. A build system that can silently answer for the wrong design is a
correctness problem, not a convenience one.

It assumes the pipelined core closes timing at 50 MHz, which only the fitter
can confirm. The single-cycle figure is on firmer ground, 12.5 MHz being
slack-rich by construction.

**Toolchain caveat.** This needs Quartus Prime Lite, which is free but
proprietary. Yosys/nextpnr do not target MAX 10, so there is no open-source
route to this board — the "entirely open-source flow" claim in the README holds
for simulation and stops holding at the bitstream.

## 2.5 RV32M — *done, both cores*

Multiply and divide, in `hdl/common/mdu.sv`: one module, one set of ISA
semantics, and a `SEQUENTIAL` parameter that picks the divider implementation.
The single-cycle core takes the combinational one, the pipelined core the
iterative one.

It landed here rather than in iteration 4 for two reasons.

**It is the first thing that makes the two designs genuinely different.** Until
M, both cores computed everything in one pass of combinational logic and
differed only in how many registers that logic was cut into. A divide cannot be
done that way at any sensible clock, so the pipelined core stalls and the
single-cycle core pays 21 ns. That turned the clock-period comparison from a 7%
difference this flow cannot measure into a 6.0x one it can.

**A divide is a variable-latency functional unit with a ready handshake**,
which is the structure iteration 3 is built out of. Learning it inside a
five-stage pipeline with one existing stall source is a great deal easier than
learning it and out-of-order commit at the same time.

What it cost the pipeline: a second stall of a different shape. `stall_id`
bubbles ID/EX and lets EX run, which is what a load-use needs; `stall_ex` holds
ID/EX and bubbles EX/MEM, which is what an unfinished instruction needs. They
cannot overlap — one instruction is not both a load and a multiply — and
`cpu.sv` orders the two pipeline-register writes on the strength of that.

The one subtlety worth knowing before touching it: an instruction that occupies
EX for 34 cycles cannot read its operands live. The bubbles the stall pushes
into EX/MEM move the forwarding selects underneath it, so the mdu captures a
and b on the cycle the divide starts. A divider that forgets this still passes
every test whose operands come from the register file.

**Still open:** the divider is restoring, one bit per cycle, 34 cycles. Radix-4
would halve that, and `rv32m.s` shows exactly what it would buy.

## 3. Out-of-order

Tomasulo-style: register rename, reservation stations, a reorder buffer,
in-order commit.

New: `hdl/` grows the rename/dispatch/ROB/RS modules, and `hvl/` needs a real
commit-log monitor to keep the verification honest.

**Done when:** CoreMark runs to completion and commits match the golden model
instruction for instruction.

## 4. Advanced features

Caches, branch prediction, superscalar issue, a faster divider — picked based
on what the IPC numbers say is actually the bottleneck. Multiply and divide
came early instead; see 2.5.

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

- **Spike lockstep.** *Done.* Both cores expose RVFI-style commit ports, the
  testbench writes one line per retired instruction under `+COMMITLOG=`, and
  `bin/compare_spike.py` walks that against `spike --log-commits` on the same
  program. `make lockstep` checks a core against the reference model; `make
  crosscheck` checks the two cores against each other and needs no Spike at
  all. Both are in [spike.md](spike.md), including what is compared and what
  is not -- memory writes are not, which is the honest remaining gap.

- **Nanosecond timing.** *Done.* `synth/` now maps to Nangate45 and runs
  OpenSTA: single-cycle 27.686 ns against pipelined 4.636 ns, a 6.0x gap, with
  logic depth corroborating at 498 against 59. Neither core infers a latch and
  both pass `hierarchy -check`, which is the real synthesizability result —
  this RTL maps to gates rather than merely linting.

  Two caveats survive, and one has been resolved. The pipelined figure is still
  inflated by the missing buffering pass (69% of its path is one unbuffered
  mux), so 6.0x is a floor rather than an estimate; closing that needs
  OpenROAD's `repair_design`, which means installing OpenROAD proper. And
  memory remains outside the synthesized module, so the single-cycle number
  omits the access that forces its board top to 12.5 MHz — it understates the
  gap further. What is no longer a caveat is the size of the difference: at 7%
  the measurement error swamped the claim, and at 6.0x it does not.

  Note also that Yosys cannot read this design directly. Its built-in frontend
  rejects any user-defined type declared at file scope, package or not, though
  packed structs inside a module are fine. Verilator and Quartus accept all of
  it, so this is a frontend limitation rather than an RTL one. `synth/` puts
  sv2v in front; yosys-slang and Synlig are the alternatives.
- **CI**, once there is a test suite worth regressing.
