# Golden-model lockstep

Every instruction the core retires is checked against Spike, the RISC-V
reference simulator, on the same program.

```bash
cd sim && make lockstep   PROG=../testcode/rv32i.s   # against Spike
cd sim && make crosscheck PROG=../testcode/rv32i.s   # the two cores against each other
```

## Why

Self-checking assembly only tests what its author thought to check. That is a
real limit rather than a theoretical one, and RV32M made it concrete: the M
extension has four values the spec fixes by decree — divide by zero, signed
overflow, the direction truncation rounds, and which operand lends the
remainder its sign — and every one is a value you look up rather than derive. A
test suite written from the same misunderstanding as the design agrees with it.

There is also a quieter gap. `rv32i.s` executes 471 instructions and asserts on
66 of them. The other 405 run unchecked: address arithmetic, `li` expansions,
the compare inside each `CHECK` macro. A wrong answer there is only caught if it
happens to propagate into something the program does assert on.

A reference model has neither gap. It checks every instruction, every time,
against an implementation nobody here wrote.

## Installing Spike

Not packaged for Ubuntu, so it is a source build. Everything it needs is in
apt:

```bash
sudo apt install -y device-tree-compiler libboost-regex-dev libboost-system-dev
git clone --depth 1 https://github.com/riscv-software-src/riscv-isa-sim.git ~/riscv-isa-sim
mkdir -p ~/riscv-isa-sim/build && cd ~/riscv-isa-sim/build
../configure --prefix=$HOME/.local
make -j"$(nproc)"
make install
```

`~/.local/bin` must be on your `PATH` — note that `~/.profile` adds it only in
a *login* shell, so `bash -c` from a script will not see it while `bash -lc`
will.

## How it works

The core writes one line per retired instruction when run with
`+COMMITLOG=<path>`:

```
80000038 00000517 x10 80000038
80000040 00752023 -
```

That is `pc`, the instruction word, and either the register written or `-`.
`bin/compare_spike.py` asks Spike for the same thing with `--log-commits`,
normalises both into the same records, and walks them in step. Only the first
disagreement is reported; everything after it is consequence rather than cause.

Three details are worth knowing, because each one is a way to get a false pass:

**Spike does not stop.** These programs end by spinning on the halt
instruction, which Spike will happily execute forever. Its output is streamed
and cut at the halt rather than collected, so a broken run ends instead of
filling the disk.

**Spike starts in its own bootrom.** It resets at `0x1000`, runs five
instructions to read the ELF entry point, and jumps. Those commits are Spike's,
not the program's, so records before the entry point are dropped.

**`-l` must not be passed alongside `--log-commits`.** Both write to stderr and
the disassembly lines `-l` adds have the same shape as commit records minus the
privilege field — which the parser treats as optional, so every instruction
would be counted twice and the logs would diverge at commit 1 for no reason.

## What is compared, and what is not

Compared: the PC of every retired instruction, the instruction word at that PC,
which register it wrote, and the value written.

Not compared:

- **Memory writes.** Spike logs stores as `mem 0x<addr> 0x<data>` and the core
  does not report them. A store bug therefore surfaces at the next load of that
  address rather than at the store itself. Every test program does load back
  what it stores, so this is a delay in *where* the failure is reported rather
  than a hole — but it is a real gap, and closing it means adding the store
  address and data to the commit trace.
- **CSRs and traps.** The core has neither, so there is nothing to compare.
- **Timing.** Spike has no notion of cycles. Everything about how long an
  instruction took stays the business of `tb_pipeline`, which is why that
  harness is not made redundant by this one — a stall that fires a cycle too
  long produces a perfectly correct commit log.

The trace carries one line more than the run reports as retired -- 471 against
470 for `rv32i.s`. Both are right: the extra line is the halt instruction
itself, which the trace records because the core did execute it, and which the
retired counter excludes because counting it would put IPC above 1.0 on a core
that retires exactly one instruction per cycle.

The instruction word is read back from the testbench's own memory image at the
committed PC rather than carried through the core. That costs nothing and keeps
96 bits of verification-only state out of the pipeline registers. It assumes
nothing self-modifies, which nothing here does.

## The cores against each other

`make crosscheck` compares the two cores' commit logs directly and needs no
Spike at all. It is worth more than it looks: the two microarchitectures share
only the decoder, the ALU and the mdu, so anything in the pipeline's own
machinery — forwarding, stalls, squashes — has no way to produce a matching log
by accident.

It is also the check to reach for first when something breaks, because it says
whether a bug is in the shared logic or in one core's control.

## Results

All four programs, both cores, every instruction:

| Program | Commits | single-cycle | pipelined |
|---|---|---|---|
| `smoke.s` | 23 | match | match |
| `rv32i.s` | 471 | match | match |
| `rv32m.s` | 397 | match | match |
| `ctest.c` | 213 | match | match |

## Does it actually catch anything?

A comparator that always says MATCH is worse than no comparator, so the same
mutation testing the rest of the suite gets applies here. Eight bugs, injected
one at a time:

| Mutation | `rv32i.s` | `rv32m.s` | lockstep | unit tbs |
|---|---|---|---|---|
| shift amount masked to 4 bits, not 5 | caught | — | **caught** | alu |
| `lbu` sign extends like `lb` | caught | — | **caught** | stage_wb |
| `jalr` does not clear bit 0 | caught | — | **caught** | stage_ex |
| `bge` compares unsigned | caught | — | **caught** | stage_ex |
| `mulh` returns the low half | — | caught | **caught** | mdu |
| `sltu` compares `<=` instead of `<` | no | no | no | alu |
| `srl` shifts by the full operand | no | no | no | alu |
| x0 readable after a write | no | no | no | none |

**Read the honest conclusion first: lockstep caught nothing the existing three
layers missed.** It is not a gap-filler here, and claiming otherwise would be
easy and wrong. What it did was catch everything the programs caught, which is
worth having for a different reason — see below.

The three survivors are worth understanding rather than patching:

- `sltu` with `<=` needs equal operands to be distinguishable, and no program
  ever executes `sltu` with equal operands. It survived every layer including
  `tb_alu`, which had an equal-operand case for `slt` and not for `sltu`. That
  gap was real and is now closed; the table shows the post-fix result.
- `srl` unmasked needs a shift of 32 or more, which no program performs. Only a
  unit test can reach that input.
- x0 is an equivalent mutant. The mutation removes the read guard while the
  write guard still discards writes to x0, so `data[0]` never becomes non-zero
  and there is nothing to observe. This was already known.

Two of those say something the lockstep cannot: **unit tests reach inputs that
no program produces.** A golden model checks the instructions you executed, not
the ones you did not.

## What it is actually for

The value is not that it catches more. It is that the assertion does not have
to exist.

`rv32m.s` catches a broken `mulh` because it contains eight explicit checks on
high multiplies. Delete those eight checks — leaving the `mulh` instructions
themselves in place, which is the situation every unasserted instruction in
every program is already in — and:

```
rv32m.s without its mulh checks:   NOT caught
lockstep on the same program:      caught
```

That is the whole argument. `rv32i.s` executes 471 instructions and asserts on
66 of them; the other 405 are checked by nothing but this. And when iteration 3
adds instructions nobody has written a test for yet, they are checked from the
first run.

The second benefit is localisation. A failing `rv32i.s` says "check 82 did not
match" and leaves you to work backwards. Lockstep says:

```
DIVERGED in length: spike 471 commits, rtl 455
  next in spike:
      455  80000738 000780e7 x1 8000073c
```

— which names the instruction that first went wrong.

## Two bugs this found in itself

Worth recording, because both made the harness silently useless rather than
loudly broken.

**`make lockstep` did nothing when the program failed.** The `trace` target had
no `-` prefix, so a program that spun until the testbench gave up returned
non-zero, make aborted, and the comparator never ran. Every mutation that broke
a program was reported as "lockstep did not catch it" — a perfect score of zero
on the first run, which is what gave it away. A failing program is exactly when
the lockstep answer matters, so `trace` now tolerates a failing run and the
testbench closes the log on every exit path rather than only on the successful
one.

**A stale trace passed the freshness check.** With the first fix in place, a
failed run left the previous program's log on disk, `test -s` was satisfied, and
the comparator happily diffed `rv32m.s`'s trace against `rv32i.s`'s ELF. The
trace is now deleted before every run. Same family as the shared FPGA build
directory: an artifact old enough to look valid is worse than a missing one.
