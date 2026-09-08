#!/usr/bin/env python3
"""Mutation testing: deliberately break a module and confirm its test notices.

    bin/mutate.py rat            # one module
    bin/mutate.py --all          # every module with cases

A passing test proves nothing on its own. It might be checking the right thing,
or it might be checking nothing at all, and the two look identical from the
outside. So every claim this repo makes about a testbench is backed by injecting
bugs into the module and confirming the test goes red. `bin/mutations.json`
holds the bugs; this runs them.

Four outcomes, and the distinction between them is the whole point:

    caught       the test ran and reported a failure. The only good result.
    NOT CAUGHT   the test ran and passed. A hole, or an equivalent mutant --
                 a change that alters the text without altering behaviour.
                 Both are worth knowing about and neither is a pass.
    BUILD FAIL   the mutation did not compile, so the test never ran. This
                 says nothing about the test. See the note on writing cases.
    HUNG         the test never terminated. It may well have detected the bug
                 and then looped before it could say so, so this is not a pass
                 either. tb_check.svh has a watchdog to make it rare.

An earlier version of this scored the last two as if they were meaningful, and
was wrong both times.

Writing cases: MUTATE BY INVERTING, NOT BY DELETING. Deleting a term tends to
leave a signal or parameter unused, which -Wall rejects, which gives a BUILD
FAIL and no information. Guard the wrong register rather than no register;
invert an enable rather than removing it. Every signal stays live and the test
gets to run.

Exit status is non-zero unless every mutation was caught, so this is usable as
a gate rather than only as a report.
"""

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
OFF = "\033[0m"

BIN = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BIN)
CASES = os.path.join(BIN, "mutations.json")

# Where a module might live. Checked in order.
HDL_DIRS = ("hdl/ooo", "hdl/common", "hdl/pipelined", "hdl/single_cycle")


def die(msg):
    print(f"{RED}[ERROR]{OFF} {msg}")
    sys.exit(2)


def make_var(name):
    """Ask sim/Makefile for one of its variables.

    The source list is not duplicated here on purpose. If this file grew its
    own copy of what a unit test compiles against, the two would drift and this
    tool would quietly start testing something other than what `make unit`
    builds.
    """
    r = subprocess.run(["make", "--no-print-directory", "-C",
                        os.path.join(ROOT, "sim"), "print-" + name],
                       capture_output=True, text=True)
    if r.returncode != 0:
        die("could not read " + name + " from sim/Makefile:\n" + r.stderr.strip())
    return r.stdout.split()


def find_module(module):
    for d in HDL_DIRS:
        p = os.path.join(ROOT, d, module + ".sv")
        if os.path.isfile(p):
            return p
    die("no such module: " + module + " (looked in " + ", ".join(HDL_DIRS) + ")")


def build(tb, objdir, srcs, flags):
    cmd = (["verilator"] + flags + ["-Mdir", objdir] + srcs
           + [os.path.join(ROOT, "hvl/unit", tb + ".sv"),
              "--top-module", tb, "-o", tb])
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    return r.returncode == 0, r.stdout + r.stderr


def run(tb, objdir):
    try:
        r = subprocess.run([os.path.join(objdir, tb)],
                           capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return "HUNG", "never terminated"
    out = r.stdout + r.stderr
    m = re.search(r"^  FAIL (\S+)\s+(.*)$", out, re.M)
    if m:
        return "caught", (m.group(1) + "  " + m.group(2)).strip()[:46]
    if re.search(r"^FAIL ", out, re.M):
        return "caught", "test reported failures"
    if re.search(r"^PASS ", out, re.M):
        return "NOT CAUGHT", ""
    lines = out.strip().splitlines()
    return "no verdict", (lines[-1][:46] if lines else "no output at all")


def mutate_module(module, cases, srcs, flags, objdir):
    """Returns (caught, total). Restores the source whatever happens."""
    target = find_module(module)
    tb = cases.get("testbench", "tb_" + module)
    entries = cases["cases"]

    before = hashlib.sha256(open(target, "rb").read()).hexdigest()
    backup = os.path.join(tempfile.gettempdir(), module + ".mutate.bak")
    shutil.copy(target, backup)

    caught = 0
    try:
        print(f"\n{module}  ({tb}, {len(entries)} mutations)")
        print("%-50s %-12s %s" % ("mutation", "outcome", "first failure reported"))
        print("-" * 110)

        for c in entries:
            src = open(target, encoding="utf-8").read()
            if c["old"] not in src:
                # Not a skip. The cases have drifted from the source, so every
                # result in this run is suspect until it is fixed.
                print("%-50s %s%-12s%s %s" % (c["name"][:50], RED,
                                              "NO MATCH", OFF,
                                              "case is stale, source has moved"))
                continue

            open(target, "w", encoding="utf-8", newline="\n").write(
                src.replace(c["old"], c["new"], 1))

            ok, log = build(tb, objdir, srcs, flags)
            if not ok:
                w = re.findall(r"%(?:Error|Warning)[^\n]*", log)
                outcome, detail = "BUILD FAIL", (w[0][:46] if w else "")
            else:
                outcome, detail = run(tb, objdir)

            shutil.copy(backup, target)

            colour = GREEN if outcome == "caught" else RED
            if outcome == "caught":
                caught += 1
            print("%-50s %s%-12s%s %s" % (c["name"][:50], colour, outcome,
                                          OFF, detail))
    finally:
        shutil.copy(backup, target)
        after = hashlib.sha256(open(target, "rb").read()).hexdigest()
        if before != after:
            die(module + ".sv was not restored cleanly -- restore it from git "
                "before trusting anything")

    return caught, len(entries)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("modules", nargs="*", help="module names, e.g. rat")
    ap.add_argument("--all", action="store_true", help="every module with cases")
    args = ap.parse_args()

    if not os.path.isfile(CASES):
        die("no mutation cases at " + CASES)
    with open(CASES) as f:
        allcases = json.load(f)

    modules = sorted(allcases) if args.all else args.modules
    if not modules:
        die("name a module, or pass --all. Have cases for: "
            + ", ".join(sorted(allcases)))
    for m in modules:
        if m not in allcases:
            die("no cases for " + m + ". Have: " + ", ".join(sorted(allcases)))

    srcs = make_var("UNIT_PKG") + make_var("UNIT_HDL")
    flags = make_var("UNIT_FLAGS")
    objdir = os.path.join(tempfile.gettempdir(), "mutate", "obj")
    os.makedirs(objdir, exist_ok=True)

    total_caught = total = 0
    for m in modules:
        c, t = mutate_module(m, allcases[m], srcs, flags, objdir)
        total_caught += c
        total += t

    print()
    if total_caught == total:
        print(f"{GREEN}all {total} mutations caught{OFF}")
        return 0
    print(f"{RED}{total - total_caught} of {total} mutations not caught{OFF}")
    print("A mutation that is not caught is either a hole in the test or an "
          "equivalent mutant.")
    print("Both are worth writing down; neither is a pass.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
