# DE10-Lite build

An FPGA target for the single-cycle core. **Untested on hardware** — everything
here is verified in simulation only, and the gap is spelled out at the bottom.

## Why this directory exists at all

`hvl/common/magic_memory.sv` reads combinationally, which no FPGA block RAM
does. On MAX 10 the situation is worse than a single wait state: the part is
LE-based with no MLAB/distributed RAM, so an asynchronous 64 KiB array would
become roughly 524,000 flip-flops against about 50,000 logic elements. It is
not a tuning problem.

The obvious fix — clock the memory on the falling edge — does not work either,
and the reason is worth stating because it drove the whole design. `dmem_addr`
comes out of the ALU, which needs `imem_rdata` first. Fetch and data access
cannot share an edge, because the data address does not exist yet when the
instruction arrives.

So one instruction takes two memory edges. `top_de10lite.sv` divides the 50 MHz
board clock by four with a phase counter:

| phase | what happens |
|---|---|
| 0 | `dmem_rdata` valid, writeback settling |
| 1 | writeback still settling, `cpu_clk` low |
| 2 | `cpu_clk` rises: PC updates, `imem_addr` settles, fetch latched at end of phase |
| 3 | `imem_rdata` valid, ALU runs, `dmem_addr` settles, data latched at end of phase |

That is 12.5 MHz for the core, with 20 ns from fetch to address and 40 ns from
load to writeback. **`hdl/cpu.sv` is unchanged** — from its point of view every
instruction still finishes in one of its own cycles.

## Building

```bash
# Generate the memory image (--mif only needed if you switch mem_sync.sv to the
# ram_init_file attribute; $readmemh reads memory_32.lst directly)
python3 bin/generate_memory_file.py --mif testcode/rv32i.s

cd fpga && quartus_sh --flow compile riscv_cpu
```

## Pin assignments are not in this repository

`riscv_cpu.qsf` has the device and source list but **no pin assignments**, on
purpose. A wrong assignment can drive a pin into contention with whatever else
is wired to it on the board, and pin maps differ between board revisions.

Import Terasic's own assignments for your board instead — their DE10-Lite
System CD ships a `.qsf` with the full set. The port names in
`top_de10lite.sv` (`MAX10_CLK1_50`, `KEY`, `SW`, `LEDR`, `HEX0`–`HEX5`) follow
Terasic's conventions so their file applies without editing.

## Reading the board

- `LEDR[0]` — halted. The program reached `slti x0, x0, -256`.
- `LEDR[1]` — memory error. An access left the 64 KiB window.
- `LEDR[9:2]` — `pc[9:2]`.
- `HEX5`–`HEX0` — the PC, in hex.

A failing test spins in its fail loop, so the PC stops and the displays hold
that address. Look it up in `sim/bin/<prog>.dis` to find the check that gave up.

## What is actually verified

`make run_fpga_sim` in `sim/` builds this exact RTL — `mem_sync.sv`,
`top_de10lite.sv`, `seven_seg.sv`, the real phase counter — against the same
programs the behavioural simulation runs, through
`hvl/verilator_fpga/top_tb.sv`. That testbench also decodes the seven-segment
outputs back to hex and checks them against the PC every cycle, so a wrong
segment map fails in simulation rather than silently producing an unreadable
board.

`rv32i.s` completes in 1572 board cycles, which is 393 core cycles against the
392 the behavioural model reports. Same core, same program, same cycle count,
through an entirely different memory.

**Not verified:** pin assignments, timing closure, and anything Quartus does.
The `.sdc` constrains the board clock and declares `cpu_clk` as a generated
clock, but whether the single-cycle critical path actually closes at 12.5 MHz
is a question only the fitter can answer.

## Known simplification

`cpu_clk` is a counter bit used as a clock. Quartus will flag it, and it is the
wrong way to build this. The clean version runs everything on the 50 MHz clock
and gives `cpu.sv` a clock enable — which the pipelined iteration needs anyway,
since it has to stall. See `docs/roadmap.md`; this whole directory is a demo
path, not the destination.
