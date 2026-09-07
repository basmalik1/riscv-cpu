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

**They are not nanoseconds.** Real timing needs a standard cell library with
timing arcs plus a static timing analyser. Yosys ships a toy `cells.lib` for
its own regression tests, not a PDK. Getting to a real clock period means
pulling in an open PDK (Sky130 or Nangate45) and OpenSTA, which is a
substantially bigger lift and is not what this directory does.

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
single_cycle   cells 5852     logic depth 44
pipelined      cells 7081     logic depth 37
```

Mapped to Nangate45, timing via OpenSTA:

```
single_cycle   critical path 4.432 ns   fmax 225.6 MHz
pipelined      critical path 4.140 ns   fmax 241.5 MHz
```

**Do not read that as a clock-period comparison.** It is 7%, and the flow that
produced it is missing a step. Yosys's `abc -liberty` maps logic to cells but
performs no buffer insertion and no gate sizing, so a net with large fanout is
charged its whole capacitance through one gate. The pipelined critical path
shows exactly that:

```
0.290  DFF_X1/Q
2.817  MUX2_X1      <- one mux, 2.8 ns
0.988  NOR3_X1
0.093  AOI211_X1
4.140  total
```

A `MUX2_X1` in this library is around 0.05 ns loaded normally. 68% of the
pipelined path sits in that single gate. The single-cycle path, by contrast,
spreads 4.432 ns across 47 cells at about 0.09 ns each, which is plausible. The
two paths are not measuring the same thing, so the ratio between them is not
meaningful.

Closing that gap needs a buffering and resizing pass after mapping --
OpenROAD's `repair_design`, which means installing OpenROAD proper rather than
OpenSTA alone. Until then **the logic depth figures below are the more
trustworthy proxy**, precisely because they count gates and are therefore
immune to the missing buffering.

Area, which does not depend on buffering and is sound as measured:

```
single_cycle   7193 cells   12302.5 um2
pipelined      8865 cells   15656.0 um2
```

The pipelined core costs **27% more area** on a real cell library, close to the
21% the generic cell count suggested. Cell counts differ between the two rows
because the generic run maps to abstract gates and the Nangate run maps to
actual library cells with different granularity; read each row internally, not
across.

The extra area is pipeline registers, the hazard unit and the forwarding muxes,
bought for **16% less logic depth**. Neither core infers a latch, and both pass
`hierarchy -check`, which is the real synthesizability result: this RTL maps to
gates, it does not merely lint.

Two things about that depth figure are worth more than the number itself.

**The critical paths are in different places.** Yosys reports where:

| Core | longest path |
|---|---|
| single-cycle | `imem_rdata` -> `regfile.rd_v` |
| pipelined | `mem_wb` -> `u_ex.alu_f` |

The single-cycle path is the whole datapath, instruction bus to register write,
which is what "single cycle" means. The pipelined path is MEM/WB, through the
writeback mux, through the forwarding network, into the ALU -- the forwarding
path, not any one stage. That is the textbook critical path of a five-stage
pipeline with forwarding, and it is why the depth only improves by 1.19x rather
than approaching the 5x the stage count might suggest. Forwarding buys back
correctness at the cost of the very path pipelining was meant to shorten.

**Memory is not in this measurement.** Only `cpu` is synthesized, and both
cores take memory as an external port. The single-cycle core's real critical
path on hardware runs *through* a memory access -- that is precisely why
`fpga/single_cycle/` needs a phase counter and runs at 12.5 MHz. So 44 against
37 compares internal logic only, and understates the single-cycle disadvantage
considerably.

That leaves two independent figures measuring different things:

- **Logic depth, 1.19x** in favour of the pipelined core. Internal logic only.
- **Board wall-clock, 3.1x to 3.75x** in favour of the pipelined core. That
  gap is dominated by memory access structure, not by internal logic.

Neither one on its own is the answer, and quoting the 3.75x without saying
where it comes from would be misleading.

## Why the flattened Verilog is kept

`build/$(CORE)/design.v` is sv2v's output, and it is worth looking at when a
synthesis error points at a line number that does not exist in the
SystemVerilog. The mapping is not always obvious.
