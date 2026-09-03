# Roadmap

Four iterations, each one a working CPU before the next starts.

## 1. Single-cycle RV32I — *current*

One instruction per cycle, zero-latency memory, no hazards to speak of.

**Done when:** every instruction in the RV32I base set executes correctly and
the tests in `testcode/` reach the halt instruction instead of their fail loop.

Remaining work is all inside `hdl/cpu.sv` and `hdl/control.sv` — every `TODO`
in those two files is a piece of the datapath.

## 2. Pipelined

Classic five stages (IF / ID / EX / MEM / WB) with forwarding and stalls.

New: pipeline registers, a hazard unit, branch resolution and flush logic,
and a memory model with real latency so stalls actually matter.

**Done when:** the same `testcode/` suite passes and IPC is measurably better
than 1/CPI of the single-cycle design at a shorter clock period.

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
  argument.
- **CI**, once there is a test suite worth regressing.
