# DE10-Lite build

FPGA targets for the DE10-Lite (MAX 10 10M50DAF484C7G). **Untested on
hardware** — everything here is verified in simulation only, and the gap is
spelled out at the bottom.

```
common/         board logic shared by every core: memory, seven segment decoder
single_cycle/   board top + Quartus project, 12.5 MHz via a phase counter
pipelined/      board top + Quartus project, 50 MHz directly
```

An `ooo/` directory drops in the same way when iteration 3 arrives.

## Why there is a board top per core

`hvl/common/magic_memory.sv` reads combinationally, which no FPGA block RAM
does. On MAX 10 it is worse than a wait state: the part is LE-based with no
MLAB or distributed RAM, so an asynchronous 64 KiB array becomes roughly
524,000 flip-flops against about 50,000 logic elements. `common/mem_sync.sv`
replaces it with a registered-read dual-port memory that infers M9K.

What differs between the cores is how that memory is driven, and it is the
whole story of iteration 2.

**Single-cycle** cannot use it directly. `dmem_addr` comes out of the ALU,
which needs `imem_rdata` first, so fetch and data access cannot share a clock
edge — the data address does not exist yet when the instruction arrives. One
instruction therefore needs two memory edges, and `single_cycle/top_de10lite.sv`
divides the 50 MHz board clock by four with a phase counter:

| phase | what happens |
|---|---|
| 0 | `dmem_rdata` valid, writeback settling |
| 1 | writeback still settling, `cpu_clk` low |
| 2 | `cpu_clk` rises: PC updates, fetch latched at end of phase |
| 3 | `imem_rdata` valid, ALU runs, data latched at end of phase |

That is 12.5 MHz for the core, and `cpu_clk` is a counter bit used as a clock,
which Quartus rightly flags.

**Pipelined** has no such problem. IF and MEM hold different instructions in
the same cycle, so both memory ports are simply enabled every cycle and the
core runs directly on the 50 MHz board clock. `pipelined/top_de10lite.sv` has
no phase counter, no divider, and no derived clock at all.

## What that is worth

Measured in simulation, same programs, same board clock:

| Test | single-cycle | pipelined | speedup |
|---|---|---|---|
| `rv32i.s` | 1748 board cycles, 34.96 µs | 466, 9.32 µs | **3.75x** |
| `ctest.c` | 852 board cycles, 17.04 µs | 275, 5.50 µs | **3.10x** |
| `smoke.s` | 92 board cycles, 1.84 µs | 30, 0.60 µs | **3.07x** |

Note where this comes from. The pipelined core has *worse* IPC — 0.937 against
1.000 — and takes more of its own cycles. It wins because it runs four times
faster, and it runs four times faster because it does not need the phase
counter. Cycles per program is the wrong axis; wall-clock time is the right
one.

**The caveat that matters:** this assumes the pipelined core actually closes
timing at 50 MHz. That is unverified, and only the fitter can answer it. If it
closes at 30 MHz instead, the ratio shrinks accordingly. The single-cycle
figure is on firmer ground, since 12.5 MHz is slack-rich by construction.

## Tools

Quartus Prime Lite, which is free but proprietary — the one non-open-source
piece in this project. Intel's bitstream format is undocumented, so Yosys and
nextpnr do not target MAX 10 and there is no open-source route to this board.
Everything up to the bitstream (simulation, verification, synthesis estimates,
timing) is open source; see the tool table in the top-level
[README](../README.md).

## Building

```bash
# Memory image. --mif is only needed if you switch mem_sync.sv to the
# ram_init_file attribute; $readmemh reads memory_32.lst directly.
python3 bin/generate_memory_file.py --mif testcode/rv32i.s

cd fpga/pipelined && quartus_sh --flow compile riscv_cpu
```

Simulate either board top before touching hardware:

```bash
cd sim && make CORE=pipelined   run_fpga_sim PROG=../testcode/rv32i.s
cd sim && make CORE=single_cycle run_fpga_sim PROG=../testcode/rv32i.s
```

## Pin assignments are not in this repository

Neither `.qsf` has pin assignments, on purpose. A wrong assignment can drive a
pin into contention with whatever else is wired to it, and pin maps differ
between board revisions.

Import Terasic's own assignments for your board instead — their DE10-Lite
System CD ships a `.qsf` with the full set. The port names in both board tops
(`MAX10_CLK1_50`, `KEY`, `SW`, `LEDR`, `HEX0`–`HEX5`) follow Terasic's
conventions so their file applies without editing.

## Reading the board

- `LEDR[0]` — halted. The program reached `slti x0, x0, -256`.
- `LEDR[1]` — memory error. An access left the 64 KiB window.
- `LEDR[9:2]` — `pc[9:2]`.
- `HEX5`–`HEX0` — the PC, in hex.

A failing test spins in its fail loop, so look the displayed address up in
`sim/bin/<prog>.dis` to find the check that gave up.

One difference between the tops: the single-cycle one drives the displays
straight from the fetch PC. The pipelined one samples it slowly, because it
redirects on every pass through `j fail` and the fetch PC cycles over the jump
plus the two instructions squashed behind it — at 50 MHz that is an unreadable
blur. The sampled value lands on one of those three, which is within 8 bytes of
the fail loop.

## What is actually verified

`make run_fpga_sim` builds the real board top — `mem_sync.sv`, the core's
`top_de10lite.sv`, `seven_seg.sv`, and the phase counter where there is one —
against the same programs the behavioural flow runs, through
`hvl/verilator_fpga/top_tb.sv`. That testbench also checks `LEDR[9:2]` against
the PC every cycle, and for the single-cycle top decodes the seven-segment
outputs back to hex and compares them too, so a wrong segment map fails in
simulation rather than producing an unreadable board.

Cycle counts match the behavioural model on both cores.

**Not verified:** pin assignments, timing closure, and anything Quartus does.
