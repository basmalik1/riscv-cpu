# Synthesis

Yosys synthesis for cell counts and logic depth, comparing the three cores.

## Install sv2v first

Yosys 0.33's built-in Verilog frontend cannot read this design. The limitation
is broader than packages: a user-defined type declared at file scope is
rejected outright (`unexpected TOK_USER_TYPE`), and so is any package import.
Packed structs declared *inside* a module do work. Verilator and Quartus accept
all of it, so this is a Yosys frontend limitation rather than an RTL one.

`sv2v` flattens SystemVerilog to Verilog-2005 in front of Yosys. Alternatives
exist -- the yosys-slang and Synlig plugins both parse SystemVerilog properly,
and OSS CAD Suite bundles a newer Yosys with sv2v already in it. sv2v is chosen
here because it is a single static binary with no version coupling to Yosys,
and because its output is plain Verilog you can read when an error points at a
line that does not exist in the source.

It is not in apt and building it needs a Haskell toolchain, so take the
prebuilt static binary from its releases:

```bash
curl -L https://github.com/zachjs/sv2v/releases/latest/download/sv2v-Linux.zip -o /tmp/sv2v.zip
unzip -j /tmp/sv2v.zip '*/sv2v' -d ~/.local/bin && chmod +x ~/.local/bin/sv2v
sv2v --version
```

Make sure `~/.local/bin` is on your `PATH`.

## Real area and timing

`make compare` needs only Yosys. Two further levels need more:

```bash
make pdk            # fetch Nangate45, one 6.4 MB liberty file
make area-compare   # real area in um2      -- needs the liberty only
make timing-compare # real critical path ns -- also needs OpenSTA
make bound-compare  # the same, next to the artifact-free lower bound
```

### The PDK

Nangate45, an open academic 45nm standard cell library, pulled from
The-OpenROAD-Project. It is not a fabrication PDK, but it carries genuine
timing arcs (2278 of them), which is what these numbers need. Chosen over
Sky130 for being a single 6.4 MB file rather than a multi-gigabyte install.
`synth/pdk/` is gitignored.

### OpenSTA

Yosys has a built-in `sta`, and it does not help here: it only understands
Yosys's own internal cell types, so given a liberty-mapped netlist it prints
`Cell type 'NOR3_X1' not recognised` for every gate and reports no paths.
Nanoseconds need a real timing analyser.

OpenSTA is not packaged for Ubuntu 24.04, so it is a source build. Everything
it needs except CUDD is in apt:

```bash
sudo apt install -y tcl-dev swig libeigen3-dev zlib1g-dev bison flex cmake
git clone https://github.com/parallaxsw/OpenSTA.git ~/OpenSTA
cd ~/OpenSTA && cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
sudo install -m755 build/sta /usr/local/bin/sta
sta -version
```

The upstream README lists CUDD as required and it is not in apt, but the
CMakeLists treats it as a findable option rather than a hard dependency, so
the build above is worth trying first. If it does object, CUDD is a small
source build of its own.

## Buffering, and why `abc.script` exists

Yosys's default `abc -liberty` script stops at the mapper. `&nf` picks a cell
for every gate, always the X1 drive, and it inserts no buffers. A net with a
thousand loads is therefore charged its whole capacitance through one
minimum-strength gate.

On a small design nothing fans out far enough for that to matter, which is why
it went unnoticed while there were two cores. The out-of-order core made it
impossible to miss: four gates driving 579, 306, 127 and 1125 loads carried
40.9 ns of a reported 46.9 ns critical path. That is a statement about the
flow, not about the design.

`synth/abc.script` is yosys's own default script with a tail added:

```
buffer -p -N 8
topo
upsize -D {D}
dnsize -D {D}
```

`buffer` builds fanout trees, `upsize` and `dnsize` pick drive strengths
against the same delay target the mapper used. It is the cheap part of what
OpenROAD's `repair_design` does, and it needs no tool this flow did not
already have. `{D}` is substituted from `ABC_PERIOD` by the Makefile, because
yosys only expands it in the inline `-script +...` form and that form cannot
carry semicolons through `-p`.

What it bought, on the same three designs:

| Core | before | after |
|---|---|---|
| single-cycle | 27.172 ns | **19.117 ns** |
| pipelined | 4.587 ns | **2.914 ns** |
| out-of-order | 46.941 ns | **7.863 ns** |

Every number in the Results section below is from the buffered flow. Anything
quoted from before it is an upper bound, since the pass only ever removes
delay.

### What it does not fix

`-p` is there because yosys maps the flip-flops itself with `dfflibmap` and
hands ABC the combinational logic alone, so every flop output arrives as a
primary input and buffering those is off by default. Turning it on changed
nothing measurable, and the reason is visible in the netlist: ABC skips the 21
sequential cells in the liberty file entirely, so it cannot see that a DFF_X1
is what drives the net and cannot put a tree between them.

One net in the out-of-order core still pays for this. `flushing` in `rob.sv`
is the squash broadcast, and it reaches every state bit a flush resets --
1504 gate inputs, all charged through one DFF_X1, for 6.814 ns of clock-to-Q.
Closing that properly needs OpenROAD's `repair_design`, which is a 57 MB
package and a technology LEF on top of the liberty file, and is not installed
here.

So the gap is measured instead of guessed. See the lower bound below.

## Usage

```bash
cd synth && make CORE=pipelined synth
cd synth && make compare              # all three cores, side by side
```

## What these numbers are, and are not

**The generic run is not nanoseconds.** `make compare` uses no library at all,
so it reports gate counts and logic depth only. Yosys ships a toy `cells.lib`
for its own regression tests, and it carries no timing arcs. Nanoseconds need
`make pdk` for the cell library and OpenSTA on top — both set up below. The
buffering pass above applies to the mapped flow only, so `make compare` is
unaffected by it either way.

**They are not the FPGA either.** Quartus maps to MAX 10 primitives — LUTs,
M9K blocks, carry chains. This maps to generic gates. The absolute numbers are
not comparable between the two flows.

**What they are good for:**

- *Logic depth* (`ltp`, longest topological path) is a proxy for critical path,
  and it is comparable between the cores because all three are mapped
  identically. It counts gates, so no buffering pass can flatter it, which
  makes it the independent check on every nanosecond figure below.
- *Cell count* is a rough area proxy, useful the same way.
- Catching RTL that lints clean but will not map to gates — inferred latches,
  combinational loops, anything Verilator tolerates that a synthesiser will not.

Read the ratio between the cores, not the absolute figures.

## Results

Generic mapping, no library:

```
single_cycle   cells 21704    logic depth 498
pipelined      cells 17644    logic depth 58
ooo            cells 55612    logic depth 79
```

Mapped to Nangate45, area:

```
single_cycle   19347 cells   27524.9 um2
pipelined      20349 cells   28233.8 um2
ooo            61172 cells   92192.4 um2
```

Timing via OpenSTA:

```
single_cycle   critical path 19.117 ns   fmax  52.3 MHz
pipelined      critical path  2.914 ns   fmax 343.1 MHz
ooo            critical path  7.863 ns   fmax 127.1 MHz
```

The out-of-order core is **three times the area** of either scalar core, and
that is where the money went: 64 physical registers where the others have 32
architectural ones, two alias tables, a 32-entry reorder buffer, and an issue
queue whose entries all shift on every issue.

**Do not read more than two significant figures into any of these.** The same
flow on the same design gives numbers a percent or two apart from run to run,
because `abc` is a heuristic optimiser and small changes upstream reshuffle its
choices. Three separate runs during the commit-trace work put the
single-cycle-to-pipelined path ratio at 6.19x, 5.97x and 5.92x. The conclusion
-- about six times -- survives that spread comfortably; a claim about the third
decimal would not. Buffering moved that ratio to 6.56x, which is the same
conclusion at better resolution rather than a different one.

All three include the RVFI-style commit ports every core exposes for
golden-model lockstep, and the 33 flip-flops `mem_wb_t` carries so that WB can
report a store. Both are inside the run-to-run noise above -- the pipelined
core measured slightly *smaller* after the store fields were added, which is a
statement about ABC rather than about the design -- and no core's critical path
runs through them. That is worth checking rather than assuming, since
verification-only logic inflating the number it is meant to verify would be a
quiet way to be wrong, and the out-of-order core is where it nearly happened:
its longest path *does* end at `commit_rd_v`, the trace read port on
`prf.sv`. Cut every trace output with `set_false_path` and the reported delay
does not move, because the same overloaded net feeds the functional logic
too -- but the check was one command away from reporting the opposite. See
[../docs/spike.md](../docs/spike.md).

### What the M extension did to these numbers

Before RV32M the two critical paths were 4.432 ns and 4.140 ns, a 7% gap this
flow cannot support a claim about. Adding multiply and divide separated them by
**about 6.6x**, and the reason is structural rather than incidental: a divide is the
first operation whose latency the two designs are forced to handle differently.
The pipelined core can stall, so it takes a one-bit-per-cycle divider that costs
34 cycles and almost no delay. The single-cycle core cannot, so it takes a
combinational divider and pays the whole thing in clock period.

Each unit measured on its own, registered on both sides, through this same
recipe — but before the buffering pass existed, so each figure is an upper
bound rather than a measurement:

| Unit | Cells | Area | Critical path |
|---|---|---|---|
| `a * b`, 32x32 combinational | 6222 | 7378 um2 | 2.923 ns |
| `a / b`, combinational | 4604 | 5759 um2 | **21.422 ns** |
| restoring divider, 1 bit/cycle | 534 | 999 um2 | 1.709 ns |

The multiply is combinational in both cores: at 2.923 ns it fits under the
pipelined core's existing path, so it costs area and no cycles. The divide is
where the designs part company, and 21.4 ns against 1.7 ns is why.

### How much of each number is still artifact

`make bound-compare` answers this rather than leaving it to judgement. It cuts
every path running through a net wider than `FANOUT_CUT` (64 by default) and
reports the worst path that survives. Nothing on that path is charged a load
the flow failed to buffer, so it is a delay the design genuinely has to pay --
a **lower bound** on the critical path.

```
ooo            reported   7.863 ns   artifact-free   3.566 ns   (11 wide nets)
pipelined      reported   2.914 ns   artifact-free   2.914 ns   (3 wide nets)
single_cycle   reported  19.117 ns   artifact-free  19.117 ns   (8 wide nets)
```

Two of the three are unchanged, which is the useful result: no wide net lies on
either scalar core's critical path, so **19.117 ns and 2.914 ns are
measurements**, not upper bounds. Both spread their delay over many gates --
the single-cycle path is 500-odd cells at roughly 0.04 ns each, which is what a
ripple through a divider actually looks like — and there is nothing left for
buffering to fix.

The out-of-order core is the one that still has a hole, and it is one net wide.
Its true critical path lies somewhere in **[3.566, 7.863] ns**; anything
quoted more precisely than that would be inventing the `flushing` buffer tree
rather than measuring it.

Logic depth corroborates all of this independently, and is immune to buffering
because it counts gates: **498, 79 and 58** for single-cycle, out-of-order and
pipelined.

### Where the critical paths are

Yosys reports the endpoints:

| Core | longest path |
|---|---|
| single-cycle | register file -> the divider -> `regfile_inst.rd_v[31]` |
| pipelined | `dmem_rdata[31]` -> `ex_mem[141]` |
| out-of-order | `u_iq.entries[239]` -> `u_prf.data[23][31]` |

The single-cycle path leaves the register file, goes through the divider, and
comes back to the register file's write port. That is the single-cycle contract
stated as a gate count: read, compute anything the ISA has, and write, inside
one edge.

The pipelined path is unchanged by M: memory read data, through the writeback
mux, through the forwarding network, into the ALU. Forwarding is still what
bounds this core, which is why adding a 2.9 ns multiplier alongside the ALU
moved it only from 4.140 to about 4.6 ns under the old flow -- the multiplier
is not on the critical path, the result mux in front of EX/MEM is.

The out-of-order path is the interesting one, and it is the iteration's whole
cost written as a gate count. It starts in an issue queue entry and ends in the
physical register file, which means one cycle contains: select the oldest ready
instruction out of the queue, mux its payload out, read two operands from a
64-entry register file, compute, and write the result back. The pipelined core
does strictly less between two registers -- a forwarding mux and an ALU -- with
pipeline registers on both sides of it. That is why 79 gates against 58, and it
is not something a branch predictor or a wider issue queue would change; it is
where the design chose to put its register boundaries.

### Memory is still not in this measurement

Only `cpu` is synthesized, and every core takes memory as an external port. The
single-cycle core's real path on hardware runs *through* a memory access, which
is why `fpga/single_cycle/` needs a phase counter and runs at 12.5 MHz. So even
19.1 ns understates it.

### And the counterweight

On the board, in simulation, wall-clock:

| Test | single-cycle | pipelined | speedup |
|---|---|---|---|
| `rv32i.s` | 1884 cycles, 37.68 us | 513, 10.26 us | **3.67x** |
| `ctest.c` | 852 cycles, 17.04 us | 275, 5.50 us | **3.10x** |
| `smoke.s` | 92 cycles, 1.84 us | 30, 0.60 us | **3.07x** |
| `rv32m.s` | 1588 cycles, 31.76 us | 1829, 36.58 us | **0.87x** |

`rv32m.s` is the one the pipelined core loses, and the number is real rather
than an artifact. 11% of that program is divides and each costs 33 stall
cycles, which a fixed 12.5 MHz board clock does not charge the single-cycle
core for. It is a pathological mix -- real code divides far less -- but it is
the honest shape of a one-bit-per-cycle divider, and radix-4 would halve it.

Two independent figures, then, measuring different things:

- **Critical path, 6.56x** in favour of the pipelined core. Internal logic only.
- **Board wall-clock, 3.07x to 3.67x** on integer code, and **0.87x** on
  divide-heavy code. Dominated by memory access structure, not internal logic.

Neither is the whole answer, and quoting either without saying where it comes
from would be misleading.

## What the out-of-order core costs, in wall-clock time

There is no `fpga/ooo` board top, so the board table above cannot be extended
to a third column. Cycles multiplied by the critical path measured here is the
comparison available, and it is the one iteration 3's done-when criterion asks
for.

Cycles first, from `sim/`:

| Test | single-cycle | pipelined | out-of-order |
|---|---|---|---|
| `smoke.s` | 22 | 29 | 39 |
| `rv32i.s` | 470 | 512 | 681 |
| `rv32m.s` | 396 | 1828 | **1742** |
| `ctest.c` | 212 | 274 | 559 |

`rv32m.s` is the one program where the out-of-order core uses fewer cycles than
the pipelined one, and that is the whole design working as intended: the
pipeline stops for 33 cycles on each of 43 divides, and the out-of-order core
keeps issuing independent work past them. It is a 4.7% win, which turns out to
be the number that matters.

Cycles times clock period, at 2.914 ns and 7.863 ns:

| Test | pipelined | out-of-order | ratio |
|---|---|---|---|
| `smoke.s` | 0.08 us | 0.31 us | 3.6x slower |
| `rv32i.s` | 1.49 us | 5.35 us | 3.6x slower |
| `rv32m.s` | 5.33 us | 13.70 us | **2.6x slower** |
| `ctest.c` | 0.80 us | 4.40 us | 5.5x slower |

And at the artifact-free lower bound of 3.566 ns, which is the most generous
figure the out-of-order core could possibly be given:

| Test | pipelined | out-of-order, best case | ratio |
|---|---|---|---|
| `rv32m.s` | 5.33 us | 6.21 us | **1.17x slower** |

**The criterion is not met, and it is not close.** For the out-of-order core to
win on `rv32m.s` it would have to hold a clock period within 4.7% of the
pipelined core's — 3.058 ns — because that is all the cycle-count win it has to
spend. Its lower bound is 3.566 ns, 17% over that budget, and its measured
figure is 7.863 ns. Logic depth says the same thing a third way and owes
nothing to any of this flow's weaknesses: 79 gates against 58.

The cause is structural and it is stated under "Where the critical paths are"
above. A single-issue out-of-order core that selects, reads a 64-entry register
file, executes and broadcasts inside one cycle has put more logic between two
registers than a five-stage pipeline does, and no amount of buffering changes
that. What would change it is cutting that path — registering between select
and register-file read, which costs a cycle of issue-to-execute latency and
means wakeup has to speculate — and that is a different machine, not a tuning
pass.

Worth being clear about what is *not* the cause, since it is the obvious
suspect: the missing branch predictor is why the out-of-order core loses on
`rv32i.s`, `ctest.c` and `smoke.s`, where every taken branch drains the machine
and walks the reorder buffer. It costs cycles, and cycles are not what this
criterion turns on. On `rv32m.s` the core already wins on cycles and loses on
clock period.

## Why the flattened Verilog is kept

`build/$(CORE)/design.v` is sv2v's output, and it is worth looking at when a
synthesis error points at a line number that does not exist in the
SystemVerilog. The mapping is not always obvious.
