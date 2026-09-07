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

```
single_cycle   cells 5852     logic depth 44
pipelined      cells 7081     logic depth 37
```

The pipelined core costs **21% more cells** -- pipeline registers, the hazard
unit and the forwarding muxes -- and buys **16% less logic depth**. Neither
core infers a latch, and both pass `hierarchy -check`, which is the real
synthesizability result: this RTL maps to gates, it does not merely lint.

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
