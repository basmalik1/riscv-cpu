# Synthesis

Yosys synthesis for cell counts and logic depth, comparing the two cores.

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

## Usage

```bash
cd synth && make CORE=pipelined synth
cd synth && make compare              # both cores, side by side
```

## What these numbers are, and are not

**The generic run is not nanoseconds.** `make compare` uses no library at all,
so it reports gate counts and logic depth only. Yosys ships a toy `cells.lib`
for its own regression tests, and it carries no timing arcs. Nanoseconds need
`make pdk` for the cell library and OpenSTA on top — both set up below. Read
the Results section before quoting any delay: the flow performs no buffering
pass, so a path that is short in gates but wide in fanout reads far slower than
it is.

**They are not the FPGA either.** Quartus maps to MAX 10 primitives — LUTs,
M9K blocks, carry chains. This maps to generic gates. The absolute numbers are
not comparable between the two flows.

**What they are good for:**

- *Logic depth* (`ltp`, longest topological path) is a proxy for critical path,
  and it is comparable between the cores because both are mapped identically.
  This is the closest thing available here to the clock-period argument behind
  iteration 2.
- *Cell count* is a rough area proxy, useful the same way.
- Catching RTL that lints clean but will not map to gates — inferred latches,
  combinational loops, anything Verilator tolerates that a synthesiser will not.

Read the ratio between the cores, not the absolute figures.

## Results

Generic mapping, no library:

```
single_cycle   cells 21694    logic depth 498
pipelined      cells 17941    logic depth 58
```

Mapped to Nangate45, area:

```
single_cycle   17946 cells   24939.9 um2
pipelined      18911 cells   26851.6 um2
```

Timing via OpenSTA:

```
single_cycle   critical path 27.448 ns   fmax  36.4 MHz
pipelined      critical path  4.431 ns   fmax 225.6 MHz
```

### What the M extension did to these numbers

Before RV32M the two critical paths were 4.432 ns and 4.140 ns, a 7% gap this
flow cannot support a claim about. Adding multiply and divide separated them by
**6.2x**, and the reason is structural rather than incidental: a divide is the
first operation whose latency the two designs are forced to handle differently.
The pipelined core can stall, so it takes a one-bit-per-cycle divider that costs
34 cycles and almost no delay. The single-cycle core cannot, so it takes a
combinational divider and pays the whole thing in clock period.

Each unit measured on its own, registered on both sides, through this same
recipe:

| Unit | Cells | Area | Critical path |
|---|---|---|---|
| `a * b`, 32x32 combinational | 6222 | 7378 um2 | 2.923 ns |
| `a / b`, combinational | 4604 | 5759 um2 | **21.422 ns** |
| restoring divider, 1 bit/cycle | 534 | 999 um2 | 1.709 ns |

The multiply is combinational in both cores: at 2.923 ns it fits under the
pipelined core's existing path, so it costs area and no cycles. The divide is
where the designs part company, and 21.4 ns against 1.7 ns is why.

### Is 6.2x trustworthy, when 7% was not?

Yes, and the reason is worth stating rather than asserting. The known defect in
this flow is that `abc -liberty` maps logic to cells but inserts no buffers and
resizes no gates, so a high-fanout net is charged its whole capacitance through
one gate. Look at where each path spends its time:

```
single_cycle   27.448 ns over 525 cells, largest single gate 0.605 ns (AOI22_X1)
pipelined       4.431 ns over  17 cells, largest single gate 3.062 ns (MUX2_X1)
```

The single-cycle path is now a genuine measurement: half a thousand gates at
roughly 0.05 ns each, which is what a ripple through a divider actually looks
like. No gate dominates and there is nothing for buffering to fix.

The pipelined path still shows the artifact -- 69% of it in one mux -- so its
true delay is **shorter** than 4.431 ns. The error therefore runs in the
direction that makes the pipelined core look worse, which makes 6.2x a floor
rather than an estimate. That is the opposite of the situation at 7%, where the
artifact was larger than the difference being claimed.

Logic depth corroborates it independently, and is immune to buffering because
it counts gates: **498 against 58, or 8.6x**.

### Where the critical paths are

Yosys reports the endpoints:

| Core | longest path |
|---|---|
| single-cycle | `regfile_inst.data[9]` -> `regfile_inst.rd_v[31]` |
| pipelined | `mem_wb[78]` -> `ex_mem_n[141]` |

The single-cycle path leaves the register file, goes through the divider, and
comes back to the register file's write port. That is the single-cycle contract
stated as a gate count: read, compute anything the ISA has, and write, inside
one edge.

The pipelined path is unchanged by M: MEM/WB, through the writeback mux,
through the forwarding network, into the ALU. Forwarding is still what bounds
this core, which is why adding a 2.9 ns multiplier alongside the ALU moved it
only from 4.140 to 4.431 ns -- the multiplier is not on the critical path, the
result mux in front of EX/MEM is.

### Memory is still not in this measurement

Only `cpu` is synthesized, and both cores take memory as an external port. The
single-cycle core's real path on hardware runs *through* a memory access, which
is why `fpga/single_cycle/` needs a phase counter and runs at 12.5 MHz. So even
27.4 ns understates it.

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

- **Critical path, 6.2x** in favour of the pipelined core, floor not estimate.
  Internal logic only.
- **Board wall-clock, 3.07x to 3.67x** on integer code, and **0.87x** on
  divide-heavy code. Dominated by memory access structure, not internal logic.

Neither is the whole answer, and quoting either without saying where it comes
from would be misleading.

## Why the flattened Verilog is kept

`build/$(CORE)/design.v` is sv2v's output, and it is worth looking at when a
synthesis error points at a line number that does not exist in the
SystemVerilog. The mapping is not always obvious.
