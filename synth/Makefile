SHELL := /bin/bash -o pipefail
.SHELLFLAGS += -e

# Yosys synthesis, for cell counts and logic depth.
#
# Two things this does NOT give you, stated up front so the numbers are not
# over-read:
#
#   * Nanoseconds. Real timing needs a standard cell library with timing arcs
#     and a static timing analyser. Yosys ships a toy cells.lib for its own
#     tests, not a PDK. What you get here is logic DEPTH, which is a proxy for
#     critical path and is comparable between the two cores because both are
#     mapped the same way.
#   * Anything about the FPGA. Quartus maps to MAX 10 primitives; this maps to
#     generic gates. The two are not comparable in absolute terms.
#
# What it is good for: comparing the cores against each other, and catching RTL
# that lints clean but will not map to gates.

CORE ?= single_cycle

# sv2v flattens SystemVerilog into Verilog-2005. Yosys 0.33's built-in frontend
# has no package support at all, so it cannot read this design directly --
# it rejects both `module m import p::*;` and a body-level import.
PKG_SRCS := $(PWD)/../pkg/types.sv $(wildcard $(PWD)/../pkg/$(CORE)_types.sv)
HDL_SRCS := $(shell find $(PWD)/../hdl/common $(PWD)/../hdl/$(CORE) -name '*.sv')

BUILD := build/$(CORE)
FLAT  := $(BUILD)/design.v

.PHONY: all
all: synth

$(FLAT): $(PKG_SRCS) $(HDL_SRCS)
	@command -v sv2v >/dev/null || { \
	    echo "sv2v not found. See synth/README.md for the one-line install."; \
	    exit 1; }
	mkdir -p $(BUILD)
	sv2v $(PKG_SRCS) $(HDL_SRCS) > $(FLAT)

.PHONY: flatten
flatten: $(FLAT)
	@echo "flattened to $(FLAT)"

.PHONY: synth
synth: $(FLAT)
	# -flatten matters: without it `ltp` reports a longest path per module,
	# and the deepest single module is not the critical path of the design.
	# -noff measures combinational depth between registers, which is the
	# quantity that sets the clock period.
	yosys -p " \
	    read_verilog $(FLAT); \
	    hierarchy -check -top cpu; \
	    synth -top cpu -flatten; \
	    stat; \
	    ltp -noff; \
	" 2>&1 | tee $(BUILD)/synth.log
	@echo
	@echo "--- summary for CORE=$(CORE) ---"
	@grep -E '^\s+Number of (cells|wires):' $(BUILD)/synth.log | tail -2
	@grep -E 'Longest topological path in cpu' $(BUILD)/synth.log | tail -1

# Both cores, side by side. The comparison is the point: absolute numbers from
# a generic mapping mean little, the ratio between two designs mapped
# identically means something.
.PHONY: compare
compare:
	@for c in single_cycle pipelined; do \
	    $(MAKE) --no-print-directory CORE=$$c synth > /dev/null 2>&1 || \
	        { echo "$$c: FAILED (see synth/build/$$c/synth.log)"; continue; }; \
	    cells=$$(grep -E '^\s+Number of cells:' build/$$c/synth.log | tail -1 | awk '{print $$4}'); \
	    ltp=$$(grep -E 'Longest topological path in cpu' build/$$c/synth.log | tail -1 | grep -oE 'length=[0-9]+' | cut -d= -f2); \
	    printf '%-14s cells %-8s logic depth %s\n' "$$c" "$$cells" "$$ltp"; \
	done

.PHONY: clean
clean:
	rm -rf $(PWD)/build
