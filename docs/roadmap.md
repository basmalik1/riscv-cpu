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

Written rather than instantiated. The ordinary route to RV32M on a commercial
flow is a vendor arithmetic macro — Synopsys DesignWare has both a pipelined
multiplier and a pipelined divider, and reaching for them is one line. There is
no open-source equivalent, and that is the point: an RV32M core that depends on
a licensed macro library is not a core anyone can rebuild. The measurements in
`mdu.sv` are what writing it instead bought and cost.

It landed here rather than in iteration 4 for two reasons.

**It is the first thing that makes the two designs genuinely different.** Until
M, both cores computed everything in one pass of combinational logic and
differed only in how many registers that logic was cut into. A divide cannot be
done that way at any sensible clock, so the pipelined core stalls and the
single-cycle core pays 21 ns. That turned the clock-period comparison from a 7%
difference this flow cannot measure into a roughly 6x one it can.

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

## 3. Out-of-order — *built and verified; half the criterion is not met*

Explicit register renaming, R10K style: a flat pool of physical registers with
a free list, a register alias table, and a reorder buffer that holds only
bookkeeping. Single-issue — one instruction renamed and dispatched per cycle,
one committed per cycle, out-of-order execution in between.

### Why explicit register renaming, and not Tomasulo

A word on motivation first, kept separate from the argument because the two are
different things.

I have built a Tomasulo machine before, and built it on proprietary tooling:
Synopsys DesignWare IP for the multiplier and divider, a licensed simulator, a
licensed synthesis flow. Doing the other style of renaming, on a toolchain
anyone can install from apt, is a good part of why this iteration interests me.
That is a preference and not a reason. The reasons follow.

Tomasulo with a reorder buffer is the other standard answer, and it is tempting
because it needs fewer structures. If a ROB slot doubles as both the rename tag
and the storage for the value, there is no physical register file to build and
no free list either.

Two things argue against it here.

**It has no seam to test against.** That saving comes from fusing tag
allocation, value storage, dependent wakeup and commit into a single module. A
design with fewer parts is not automatically simpler to verify — it is simpler
to *write*, and then the first thing capable of checking any of it is a whole
working core. Building this iteration one tested component at a time is the
plan, and that style does not allow it.

**It stores every result twice**, once in the ROB entry and once again in each
reservation-station entry that captured it off the broadcast. Two copies of a
value are two things that can disagree, and the bugs that follow are of the
kind that only appear under a particular timing of the broadcast. A physical
register file has exactly one place a value ever lives.

### Components, each tested before anything is wired together

| Component | State |
|---|---|
| `fifo` — the circular queue the free list and instruction queue are built on | done |
| `free_list` — a FIFO of physical tags | done |
| `rat` — architectural to physical map, plus the retirement copy | done |
| `prf` — physical registers with ready bits | done |
| `rob` — bookkeeping only, since the PRF holds the values | done |
| `issue_queue` — wakeup and select | done |
| `fetch` — program counter, redirected at commit | done |
| `dispatch` — rename, all four allocations or none | done |
| `execute` — three paths, one result bus | done |
| `cpu` — the top level, and commit | done |

All of it is built, unit tested, and mutation tested, and the assembled core
matches Spike instruction for instruction on all four programs.

Two decisions in the issue queue are worth knowing before reading it. It
COMPACTS -- entries shift down on issue, so an entry's index is its age and
selecting the oldest ready instruction is a priority encoder rather than an age
matrix. And selection reads the REGISTERED ready bits, not the ones this
cycle's broadcast is setting, so an instruction woken in cycle N issues in N+1
and never in N. That second one is forced by `prf.sv`: the broadcast value does
not reach the register file until the cycle ends, so issuing during N would
read the previous contents.

Recovery is settled, and it is the mirror of the commit rule. A COMMITTED
instruction releases the physical register it DISPLACED, because its own now
holds architectural state; a SQUASHED one releases its OWN, because it never
became architectural. So after a mispredicting instruction commits, the reorder
buffer walks the entries behind it and hands each one's register back, one per
cycle, through the same free-list port commit uses. That costs a cycle per
in-flight instruction and is why `free_list` and `rat` need no flush ports of
their own — the reorder buffer drives their ordinary ones.

**Done when:** `make lockstep` passes on every program in `testcode/` for the
out-of-order core, and that core beats the pipelined one in wall-clock time on
`rv32m.s`.

The second half is the honest measure of what this iteration buys, and it is
worth being precise about why it is not an IPC target. **A single-issue
out-of-order core cannot beat IPC 1.0 either** — it commits one instruction per
cycle at best, exactly like the pipeline, and the same correction that applies
to iteration 2 applies here. What it buys is latency tolerance: the pipelined
core stops the entire machine for 33 cycles on every divide, 43 times over in
`rv32m.s`, while an out-of-order core keeps issuing independent work past it.
`rv32m.s` is the one program already in the tree where that difference shows,
and it is the case the pipelined core currently *loses* on the board.

**Not** CoreMark, which this section used to ask for. CoreMark needs a porting
layer plus a C library with `printf` and a timer, and this toolchain ships
neither — see the Setup section of the README. Getting it running is real work
of its own and says nothing about whether the core is correct.

### Measured: the first half holds, the second does not

**Lockstep passes.** Twelve runs, three cores against Spike on all four
programs, every one identical instruction for instruction. That half is done.

**The wall-clock claim fails.** Cycles first:

| Test | single-cycle | pipelined | out-of-order |
|---|---|---|---|
| `smoke.s` | 22 | 29 | 39 |
| `rv32i.s` | 470 | 512 | 681 |
| `rv32m.s` | 396 | 1828 | **1742** |
| `ctest.c` | 212 | 274 | 559 |

`rv32m.s` is the case this iteration was aimed at, and on cycles it works: the
out-of-order core issues past a divide the pipeline has to stop for, and takes
1742 cycles against 1828. That is the latency tolerance the section above
promised, and it is the only program in the tree where it shows.

It is a 4.7% win, and 4.7% is the entire budget available for clock period.
Synthesis says the budget is not close to enough:

| Core | critical path | logic depth |
|---|---|---|
| pipelined | 2.914 ns | 58 |
| out-of-order | 7.863 ns | 79 |

`rv32m.s` in wall-clock time is therefore 5.33 us pipelined against 13.70 us
out-of-order — **2.6x the wrong way**. Even granting the out-of-order core the
most generous figure its measurement supports, 3.566 ns, it comes to 6.21 us
and still loses by 17%. Three separate quantities — measured delay, an
artifact-free lower bound on it, and a gate count that no synthesis weakness
can flatter — all say the same thing.

### Why, and why the obvious suspect is the wrong one

The tempting explanation is the missing branch predictor, and it is wrong for
this criterion. Predict-not-taken resolved at commit is why the out-of-order
core loses on `rv32i.s`, `ctest.c` and `smoke.s`: every taken branch drains the
machine and walks the reorder buffer behind it. That costs **cycles**. On
`rv32m.s` the cycle count is already a win. What is lost there is **clock
period**, and a branch predictor does not shorten a critical path.

The real cause is where the design put its register boundaries. Yosys reports
the longest path as `u_iq.entries[239]` to `u_prf.data[23][31]` — from an issue
queue entry into the physical register file. One cycle therefore holds: select
the oldest ready instruction, mux its payload out of the queue, read two
operands from a 64-entry register file, compute, and broadcast the result back.
The pipelined core puts a forwarding mux and an ALU between two registers and
nothing else. 79 gates against 58 is that difference counted.

Fixing it means cutting that path — a register between select and register-file
read, so issue and execute are separate cycles. That costs a cycle of
issue-to-execute latency and forces wakeup to speculate on the result of an
instruction that has not read its operands yet, which is what a real machine
does and is a redesign of the wakeup loop rather than a tuning pass.

### What this iteration did buy

Stating it plainly, since the criterion it set itself is not met:

- A correct single-issue out-of-order machine, R10K style, verified to the same
  standard as the other two cores — Spike lockstep on four programs, unit tests
  on all eleven modules, and a mutation gate over the lot.
- Confirmation that the latency-tolerance argument is real: `rv32m.s` is faster
  in cycles, and it is faster for exactly the predicted reason.
- The measurement that says the design is bounded by its issue-to-writeback
  path rather than by anything speculative, which is what makes the next
  iteration's target obvious rather than a guess.

What it does not buy is a faster processor, and the criterion was right to ask
for one. Restating the criterion so that it passes would be the dishonest
version of this section; the useful version is that a single-issue out-of-order
core that resolves select, register read and execute in one cycle cannot beat a
five-stage pipeline on wall-clock time, and that is now measured rather than
suspected.

## 4. Advanced features

Caches, branch prediction, superscalar issue, a faster divider — picked based
on what the numbers say is actually the bottleneck. Multiply and divide came
early instead; see 2.5.

Iteration 3 turned that from a list into an order, because it produced the two
measurements that rank it:

1. **Cut the issue-to-writeback path.** This is what the out-of-order core
   loses on and nothing else on this list touches it. A register between select
   and register-file read, and a wakeup loop that speculates across it.
2. **Branch prediction.** Worth 3 of the 4 programs' cycle counts, and cheap
   next to the above. It is second only because it cannot fix the criterion
   iteration 3 failed.
3. **A radix-4 divider**, which `rv32m.s` has been asking for since 2.5.

Superscalar issue and caches stay after those: both make a machine that is
already clock-period bound wider, and widening the thing that is too slow is
the wrong order to do the work in.

## Memory model per iteration

Each iteration gets the simplest memory that makes its hazards real. Reaching
for a realistic model early just adds noise to debug through: a memory that can
stall or reorder is only worth modelling once the core can do something about
it.

| Model | Read latency | Iteration | What it makes real |
|---|---|---|---|
| Combinational / "magic" | 0 | 1 — single-cycle | nothing; anything slower breaks the one-cycle contract |
| Synchronous read (true BRAM) | 1, fixed | 2 — pipelined, and 3's first cut | load-use hazards, IF/MEM stage stalls |
| Variable latency + `resp` handshake | variable | 3, once there is a load/store queue | something worth reordering around |
| Burst SDRAM + FR-FCFS | long, reordered | 4 — advanced | what caches and prefetch get measured against |

Three consequences worth remembering:

- A synchronous read is not an option in iteration 1. It forces either 2 cycles
  per instruction or a negedge-clocked memory hack, and neither is a
  single-cycle design any more.
- Iteration 3 does **not** start on variable-latency memory, despite the row
  above once saying it did. The first out-of-order cut keeps the fixed 1-cycle
  synchronous read and keeps loads and stores in program order relative to each
  other. Rename, wakeup and precise commit are enough new machinery to debug at
  once; memory disambiguation is its own step, and the variable-latency model
  only becomes worth having when there is a load/store queue able to do
  something about it.
- The `resp` handshake is deliberately *not* pre-built, for the same reason it
  was not pre-built for iteration 2: each iteration rewrites the core's top
  level wholesale, so a handshake added before the structure that uses it just
  becomes something to port.

---

## Infrastructure deferred until it is needed

- **Spike lockstep.** *Done.* Both cores expose RVFI-style commit ports, the
  testbench writes one line per retired instruction under `+COMMITLOG=`, and
  `bin/compare_spike.py` walks that against `spike --log-commits` on the same
  program. `make lockstep` checks a core against the reference model; `make
  crosscheck` checks the two cores against each other and needs no Spike at
  all. Both are in [spike.md](spike.md), including what is compared and what
  is not -- memory writes are not, which is the honest remaining gap.

- **Nanosecond timing.** *Done.* `synth/` maps to Nangate45 and runs OpenSTA:
  single-cycle 19.117 ns against pipelined 2.914 ns, a gap of about 6.6x, with
  logic depth corroborating at 498 against 58. Two significant figures is all
  this flow supports; repeated runs move the ratio by a percent or two. No core
  infers a latch and all three pass `hierarchy -check`, which is the real
  synthesizability result — this RTL maps to gates rather than merely linting.

  The buffering caveat that used to sit here is mostly gone. `synth/abc.script`
  adds `buffer`, `upsize` and `dnsize` after the mapper, which cut the three
  cores from 27.172 / 4.587 / 46.941 ns to 19.117 / 2.914 / 7.863. And the size
  of what remains is now measured rather than estimated: `make bound-compare`
  cuts every path through a net wider than 64 loads and reports the worst path
  left, which for both scalar cores is the reported path unchanged. Those two
  numbers are measurements.

  Two caveats survive. The out-of-order core still carries one 1504-fanout
  squash broadcast that no pass in this flow can buffer, because yosys owns the
  flip-flops and ABC cannot see them — so its critical path is known only to
  lie in [3.566, 7.863] ns, and closing that needs OpenROAD's `repair_design`.
  And memory remains outside the synthesized module, so the single-cycle number
  omits the access that forces its board top to 12.5 MHz — it understates the
  gap further.

  Note also that Yosys cannot read this design directly. Its built-in frontend
  rejects any user-defined type declared at file scope, package or not, though
  packed structs inside a module are fine. Verilator and Quartus accept all of
  it, so this is a frontend limitation rather than an RTL one. `synth/` puts
  sv2v in front; yosys-slang and Synlig are the alternatives.
- **CI**, once there is a test suite worth regressing.
