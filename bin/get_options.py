#!/usr/bin/env python3
"""Expose fields of options.json to the Makefiles: `get_options.py <key>`."""

import json
import os
import sys

os.chdir(os.path.dirname(os.path.abspath(__file__)))
os.chdir("..")

with open("options.json") as f:
    opts = json.load(f)

key = sys.argv[1]

if key == "clock":
    if opts["clock"] % 2 != 0 or opts["clock"] < 0:
        print("Error: clock period must be an even positive number", file=sys.stderr)
        sys.exit(1)
    print(int(opts["clock"]))

elif key in ("arch", "abi"):
    print(opts[key])

elif key == "timeout":
    print(int(opts["timeout"]))

elif key in ("mem_base", "mem_size"):
    print(int(opts[key], 0))

else:
    print(f"Error: unknown option '{key}'", file=sys.stderr)
    sys.exit(1)
