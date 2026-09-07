#!/usr/bin/env python3
"""Lockstep the RTL against Spike, the RISC-V reference simulator.

    compare_spike.py <rtl-commit.log> <prog.elf>
    compare_spike.py --diff <log-a> <log-b>

The core writes one line per retired instruction when run with
`+COMMITLOG=<path>` (see hvl/common/top_tb.svh):

    80000004 00500293 x5 00000005              a register was written
    80000014 05c39263 -                        nothing was written
    80000040 00752023 - mem 80000064 0000000c  a store

Spike is asked for the same thing with `--log-commits`, its output is
normalised into the same records, and the two are walked in step. The first
place they disagree is reported with context; everything after it is noise, so
nothing else is.

Why this exists. Self-checking assembly only tests what its author thought to
check, and the M extension made that limit concrete -- four values the spec
fixes by decree, each of which a plausible implementation gets plausibly wrong,
and each of which a hand-written test only catches if somebody remembered it.
A reference model has no such gap: it checks every instruction, every time,
against an implementation that is not ours.

Two things Spike needs help with, both handled here:

  * It does not stop. Our programs end by spinning on the halt instruction,
    which Spike will happily execute forever, so its output is streamed and cut
    at the halt rather than collected.

  * It starts in its own bootrom at 0x1000 and jumps to the ELF entry, so the
    first few commits are Spike's and not the program's. Records before the
    entry point are dropped.
"""

import os
import re
import subprocess
import sys

RED = "\033[31m"
GREEN = "\033[32m"
DIM = "\033[2m"
OFF = "\033[0m"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# The project's halt convention: slti x0, x0, -256. Both sides stop here.
HALT_INST = 0xF0002013

# Spike's commit records look like
#     core   0: 3 0x0000000080000000 (0x00000413) x8  0x00000000
# where the privilege digit is present only in some versions, and a write may
# be a register, a CSR, or memory. Kept deliberately loose: the format has
# drifted between Spike releases and the parts we need have not.
SPIKE_RE = re.compile(
    r"^core\s+\d+:\s+(?:\d+\s+)?0x([0-9a-fA-F]+)\s+\(0x([0-9a-fA-F]+)\)(.*)$")
SPIKE_REG_RE = re.compile(r"\bx\s*(\d+)\s+0x([0-9a-fA-F]+)")

# A store prints two operands, `mem 0x<addr> 0x<data>`; a load prints only the
# address it read. The optional second group is what tells them apart.
#
# Spike pads the stored value to the WIDTH of the access -- 0xaa for a byte,
# 0xbeef for a halfword, 0x89abcdef for a word -- so the digit count carries
# the size. The testbench writes its side the same way, which is what lets a
# byte store be distinguished from a word store sharing its low byte.
SPIKE_MEM_RE = re.compile(r"\bmem\s+0x([0-9a-fA-F]+)(?:\s+0x([0-9a-fA-F]+))?")

RTL_RE = re.compile(
    r"^([0-9a-fA-F]{8}) ([0-9a-fA-F]{8}) "
    r"(?:x(\d+) ([0-9a-fA-F]{8})|-)"
    r"(?: mem ([0-9a-fA-F]{8}) ([0-9a-fA-F]+))?\s*$")


def die(msg):
    print(f"{RED}[ERROR]{OFF} {msg}")
    sys.exit(1)


def get_option(key):
    out = subprocess.run(
        [sys.executable, os.path.join(SCRIPT_DIR, "get_options.py"), key],
        capture_output=True, text=True)
    if out.returncode != 0:
        die(f"get_options.py {key} failed: {out.stderr.strip()}")
    return out.stdout.strip()


class Commit:
    """One retired instruction, in whichever form it arrived."""

    __slots__ = ("pc", "inst", "rd", "val", "st_addr", "st_val", "st_w")

    def __init__(self, pc, inst, rd, val, st_addr=None, st_val=None, st_w=None):
        self.pc = pc
        self.inst = inst
        self.rd = rd            # None when no register was written
        self.val = val
        self.st_addr = st_addr  # None when the instruction did not store
        self.st_val = st_val
        self.st_w = st_w        # store width in bytes: 1, 2 or 4

    def __eq__(self, other):
        return (self.pc == other.pc
                and self.inst == other.inst
                and self.rd == other.rd
                and self.val == other.val
                and self.st_addr == other.st_addr
                and self.st_val == other.st_val
                and self.st_w == other.st_w)

    def __str__(self):
        head = (f"{self.pc:08x} {self.inst:08x} -" if self.rd is None
                else f"{self.pc:08x} {self.inst:08x} x{self.rd} {self.val:08x}")
        if self.st_addr is None:
            return head
        return f"{head} mem {self.st_addr:08x} {self.st_val:0{self.st_w * 2}x}"


def read_rtl(path):
    out = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            if not line.strip():
                continue
            m = RTL_RE.match(line)
            if not m:
                die(f"{path}:{n}: cannot parse RTL commit line: {line.rstrip()}")
            pc, inst, rd, val, sa, sv = m.groups()
            out.append(Commit(int(pc, 16), int(inst, 16),
                              int(rd) if rd else None,
                              int(val, 16) if val else None,
                              int(sa, 16) if sa else None,
                              int(sv, 16) if sv else None,
                              len(sv) // 2 if sv else None))
    return out


def parse_spike_line(line):
    """One Spike commit record, or None if the line is not one."""
    m = SPIKE_RE.match(line)
    if not m:
        return None
    pc = int(m.group(1), 16) & 0xFFFFFFFF
    inst = int(m.group(2), 16) & 0xFFFFFFFF
    tail = m.group(3)

    # A CSR write reads as `c768_mstatus 0x...` and a memory write as
    # `mem 0x...`; neither is a register write, and this core has no CSRs.
    rd = val = None
    reg = SPIKE_REG_RE.search(tail)
    if reg:
        rd = int(reg.group(1))
        val = int(reg.group(2), 16) & 0xFFFFFFFF

    # x0 discards its write on both sides. Calling it a write here would be a
    # difference from the RTL that is not a difference in behaviour.
    if rd == 0:
        rd = val = None

    st_addr = st_val = st_w = None
    mem = SPIKE_MEM_RE.search(tail)
    if mem and mem.group(2) is not None:      # two operands means a store
        st_addr = int(mem.group(1), 16) & 0xFFFFFFFF
        st_val = int(mem.group(2), 16)
        st_w = len(mem.group(2)) // 2

    return Commit(pc, inst, rd, val, st_addr, st_val, st_w)


def run_spike(elf, entry_pc, want, isa, mem_base, mem_size):
    """Stream Spike, keeping commits from the ELF entry to the halt.

    `want` bounds how long we are willing to wait for the halt: our programs
    fail by spinning, so a broken run would otherwise never end.
    """
    # --log-commits only, deliberately without -l. Both write to stderr, and
    # the disassembly lines -l adds have the same shape as commit records
    # minus the privilege field -- which the record regex treats as optional,
    # so every instruction would be counted twice.
    cmd = ["spike", f"--isa={isa}", f"-m0x{mem_base:x}:0x{mem_size:x}",
           "--log-commits", elf]

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True,
                                bufsize=1)
    except FileNotFoundError:
        die("spike not found on PATH. See docs/spike.md for the build.")

    commits = []
    started = False
    limit = want * 4 + 10000      # generous: a divergence may add instructions
    try:
        for line in proc.stderr:
            c = parse_spike_line(line)
            if c is None:
                continue
            # Everything before the ELF entry is Spike's own bootrom.
            if not started:
                if c.pc != entry_pc:
                    continue
                started = True
            commits.append(c)
            if c.inst == HALT_INST or len(commits) > limit:
                break
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    if not commits:
        die("spike produced no commit records at the entry point. Run it by "
            "hand to see what it said:\n         " + " ".join(cmd))
    return commits


def elf_entry(elf):
    out = subprocess.run(["riscv64-unknown-elf-readelf", "-h", elf],
                         capture_output=True, text=True)
    if out.returncode != 0:
        die("readelf failed on " + elf)
    for line in out.stdout.splitlines():
        if "Entry point address" in line:
            return int(line.split(":")[1].strip(), 16)
    die("no entry point in " + elf)


def compare(a, b, name_a, name_b):
    """Walk both in step. Report the first disagreement and nothing after."""
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            print(f"{RED}DIVERGED{OFF} at commit {i}\n")
            lo = max(0, i - 4)
            print(f"  {DIM}{'':>5}  {name_a:<48}  {name_b}{OFF}")
            for j in range(lo, min(n, i + 3)):
                mark = f"{RED}>{OFF}" if j == i else " "
                print(f"{mark} {j:>5}  {str(a[j]):<48}  {str(b[j])}")
            print()
            # Say what actually differs, since two records can differ in one
            # field and reading hex side by side is how mistakes get made.
            def hexf(v):
                return "(none)" if v is None else f"{v:08x}"

            def regf(v):
                return "(no write)" if v is None else f"x{v}"

            def sizef(v):
                return "(no store)" if v is None else f"{v} byte(s)"

            for what, x, y, fmt in (("pc", a[i].pc, b[i].pc, hexf),
                                    ("instruction", a[i].inst, b[i].inst, hexf),
                                    ("rd", a[i].rd, b[i].rd, regf),
                                    ("value", a[i].val, b[i].val, hexf),
                                    ("store addr", a[i].st_addr, b[i].st_addr, hexf),
                                    ("store data", a[i].st_val, b[i].st_val, hexf),
                                    ("store width", a[i].st_w, b[i].st_w, sizef)):
                if x != y:
                    print(f"  {what:<12} {name_a} {fmt(x)}   {name_b} {fmt(y)}")
            return 1

    if len(a) != len(b):
        print(f"{RED}DIVERGED{OFF} in length: "
              f"{name_a} {len(a)} commits, {name_b} {len(b)}")
        print("  They agree on every instruction up to the shorter of the two,")
        print("  so this is a run that stopped early rather than a wrong answer.")
        longer, ln = (a, name_a) if len(a) > len(b) else (b, name_b)
        print(f"\n  next in {ln}:")
        for j in range(n, min(len(longer), n + 4)):
            print(f"    {j:>5}  {longer[j]}")
        return 1

    print(f"{GREEN}MATCH{OFF}  {len(a)} commits identical "
          f"({name_a} vs {name_b})")
    return 0


def main():
    args = sys.argv[1:]

    if args and args[0] == "--diff":
        if len(args) != 3:
            die("usage: compare_spike.py --diff <log-a> <log-b>")
        # Both sides are usually named commit.log; the directory is what says
        # which core produced it.
        def label(path):
            return os.path.join(os.path.basename(os.path.dirname(path)),
                                os.path.basename(path))
        return compare(read_rtl(args[1]), read_rtl(args[2]),
                       label(args[1]), label(args[2]))

    if len(args) != 2:
        die("usage: compare_spike.py <rtl-commit.log> <prog.elf>\n"
            "         compare_spike.py --diff <log-a> <log-b>")

    rtl_log, elf = args
    for p in (rtl_log, elf):
        if not os.path.isfile(p):
            die("no such file: " + p)

    rtl = read_rtl(rtl_log)
    if not rtl:
        die(rtl_log + " is empty -- did the run get +COMMITLOG?")

    isa = get_option("arch")
    mem_base = int(get_option("mem_base"))
    mem_size = int(get_option("mem_size"))

    golden = run_spike(elf, elf_entry(elf), len(rtl), isa, mem_base, mem_size)
    return compare(golden, rtl, "spike", "rtl")


if __name__ == "__main__":
    sys.exit(main())
