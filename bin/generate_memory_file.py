#!/usr/bin/env python3
"""Compile a RISC-V .s/.c source (or take an existing .elf) and emit the
word-addressable memory image that hvl/common/magic_memory.sv loads.

Usage: generate_memory_file.py <src.s | src.c | prog.elf> [more sources...]

Outputs into sim/bin/: <stem>.elf, <stem>.dis, memory_32.lst
"""

import os
import pathlib
import subprocess
import sys

RED = "\033[31m"
OFF = "\033[0m"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WORK_DIR = os.path.join(SCRIPT_DIR, "..", "sim", "bin")
STARTUP = os.path.join(SCRIPT_DIR, "startup.s")
LINKER = os.path.join(SCRIPT_DIR, "link.ld")

GCC = "riscv64-unknown-elf-gcc"
OBJDUMP = "riscv64-unknown-elf-objdump"
OBJCOPY = "riscv64-unknown-elf-objcopy"


def die(msg):
    print(f"{RED}[ERROR]{OFF} {msg}")
    sys.exit(1)


def get_option(key):
    out = subprocess.run(
        [sys.executable, os.path.join(SCRIPT_DIR, "get_options.py"), key],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        die(f"get_options.py {key} failed: {out.stderr.strip()}")
    return out.stdout.strip()


def run(cmd, what):
    if subprocess.run(cmd).returncode != 0:
        die(f"{what} failed")


sources = [os.path.abspath(v) for v in sys.argv[1:]]
if not sources:
    die(f"no input file\n[INFO]  Usage: {os.path.basename(__file__)} <src.s | src.c | prog.elf>")

arch = get_option("arch")
abi = get_option("abi")
mem_base = int(get_option("mem_base"))
mem_size = int(get_option("mem_size"))

os.makedirs(WORK_DIR, exist_ok=True)
stem = pathlib.Path(sources[0]).stem
elf_file = os.path.join(WORK_DIR, stem + ".elf")
dis_file = os.path.join(WORK_DIR, stem + ".dis")
bin_file = os.path.join(WORK_DIR, stem + ".bin")
lst_file = os.path.join(WORK_DIR, "memory_32.lst")

for stale in (dis_file, bin_file, lst_file):
    if os.path.isfile(stale):
        os.remove(stale)

if len(sources) == 1 and pathlib.Path(sources[0]).suffix.lower() == ".elf":
    elf_file = sources[0]
else:
    # A hand-written .s brings its own entry point; C sources need startup.s.
    crt = [] if pathlib.Path(sources[0]).suffix.lower() in (".s", ".asm") else [STARTUP]
    if os.path.isfile(elf_file):
        os.remove(elf_file)
    run([GCC,
         f"-march={arch}", f"-mabi={abi}",
         "-mcmodel=medany", "-ffreestanding", "-nostdlib",
         "-Wl,--no-relax", "-Wl,--no-warn-rwx-segments",
         "-Wl,--defsym,_mem_base=%d" % mem_base,
         "-Wl,--defsym,_mem_size=%d" % mem_size,
         "-T", LINKER, "-O2", "-Wall", "-Wextra", "-Wno-unused",
         *crt, *sources, "-lgcc", "-o", elf_file], "compile")
    print(f"[INFO]  Compiled to {elf_file}")

with open(dis_file, "w") as f:
    if subprocess.run([OBJDUMP, "-D", "-Mnumeric", elf_file], stdout=f).returncode != 0:
        die("disassembly failed")
print(f"[INFO]  Disassembled to {dis_file}")

hdrs = subprocess.run([OBJDUMP, "-h", elf_file], capture_output=True, text=True)
if hdrs.returncode != 0:
    die("objdump -h failed")

# objdump -h prints a two-line record per section; line 1 holds name/size/VMA.
sections = [line.split() for line in hdrs.stdout.splitlines()[5::2]]

with open(lst_file, "w") as lst:
    for sec in sections:
        name, size, vma = sec[1], int(sec[2], 16), int(sec[3], 16)
        if size == 0:
            continue
        if vma % 4 != 0 or size % 4 != 0:
            die(f"section {name} is not word aligned")
        if vma < mem_base or vma + size > mem_base + mem_size:
            die(f"section {name} at {vma:#x}+{size:#x} falls outside the "
                f"{mem_size:#x}-byte memory at {mem_base:#x}")

        run([OBJCOPY, "-O", "binary", "-j", name, elf_file, bin_file], "objcopy")
        with open(bin_file, "rb") as f:
            blob = f.read()
        os.remove(bin_file)
        if not blob:
            continue

        # $readmemh addresses index the array, which starts at mem_base.
        lst.write(f"@{(vma - mem_base) >> 2:08x}\n")
        for i in range(0, len(blob), 4):
            word = int.from_bytes(blob[i:i + 4].ljust(4, b"\x00"), "little")
            lst.write(f"{word:08x}\n")
        lst.write("\n")

print(f"[INFO]  Wrote memory contents to {lst_file}")
