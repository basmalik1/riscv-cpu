SHELL := /bin/bash -o pipefail
.SHELLFLAGS += -e

# Synthesis and timing.
#
# Three levels, each needing one more tool than the last:
#
#   make compare   cell count and logic depth       yosys + sv2v
#   make area      real area in um2                 + a liberty file (make pdk)
#   make timing    real critical path in ns         + OpenSTA
#
# Yosys has a built-in `sta`, but it only understands its own internal cell
# types -- given a liberty-mapped netlist it reports "cell type not recognised"
# for every gate and finds no paths. Real numbers need OpenSTA. See README.

CORE ?= single_cycle

# sv2v flattens SystemVerilog to Verilog-2005. Yosys's built-in frontend
# rejects any user-defined type declared at file scope, package or not.
PKG_SRCS := $(PWD)/../pkg/types.sv $(wildcard $(PWD)/../pkg/$(CORE)_types.sv)
HDL_SRCS := $(shell find $(PWD)/../hdl/common $(PWD)/../hdl/$(CORE) -name '*.sv')

BUILD  := build/$(CORE)
FLAT   := $(BUILD)/design.v
MAPPED := $(BUILD)/mapped.v

# Nangate45, an open academic standard cell library. Not a real fabrication
# PDK, but it carries genuine timing arcs, which is what matters here. Chosen
# over Sky130 for being one 6.4 MB file rather than a multi-gigabyte install.
LIBERTY := pdk/NangateOpenCellLibrary_typical.lib
LIB_URL := https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib

# Two separate numbers, and conflating them gives a misleading answer.
#
# ABC_PERIOD is what the mapper optimises towards. Set it loose and ABC stops
# work once it is met, so the measured delay reflects the constraint rather
# than the design. Set deliberately tight so it optimises as hard as it can.
#
# PERIOD is only the reference the STA reports slack against. The number that
# matters is the data arrival time, which is the achieved critical path.
ABC_PERIOD ?= 1.0
PERIOD     ?= 10.0

.PHONY: all
all: compare

# ---------------------------------------------------------------- sources
$(FLAT): $(PKG_SRCS) $(HDL_SRCS)
	@command -v sv2v >/dev/null || { \
	    echo "sv2v not found. See synth/README.md."; exit 1; }
	mkdir -p $(BUILD)
	sv2v $(PKG_SRCS) $(HDL_SRCS) > $(FLAT)

.PHONY: flatten
flatten: $(FLAT)
	@echo "flattened to $(FLAT)"

.PHONY: pdk
pdk: $(LIBERTY)

$(LIBERTY):
	mkdir -p pdk
	curl -L --max-time 300 -o $(LIBERTY) $(LIB_URL)
	@echo "fetched $$(du -h $(LIBERTY) | cut -f1) to $(LIBERTY)"

# ------------------------------------------------- generic: cells and depth
# -flatten matters: without it `ltp` reports a longest path per module, and the
# deepest single module is not the critical path. -noff measures combinational
# depth between registers, which is the quantity that sets the clock period.
.PHONY: synth
synth: $(FLAT)
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

.PHONY: compare
compare:
	@for c in single_cycle pipelined; do \
	    $(MAKE) --no-print-directory CORE=$$c synth > /dev/null 2>&1 || \
	        { echo "$$c: FAILED (see synth/build/$$c/synth.log)"; continue; }; \
	    cells=$$(grep -E '^\s+Number of cells:' build/$$c/synth.log | tail -1 | awk '{print $$4}'); \
	    ltp=$$(grep -E 'Longest topological path in cpu' build/$$c/synth.log | tail -1 | grep -oE 'length=[0-9]+' | cut -d= -f2); \
	    printf '%-14s cells %-8s logic depth %s\n' "$$c" "$$cells" "$$ltp"; \
	done

# ------------------------------------------- mapped to real standard cells
$(MAPPED): $(FLAT) $(LIBERTY)
	yosys -p " \
	    read_verilog $(FLAT); \
	    hierarchy -check -top cpu; \
	    synth -top cpu -flatten; \
	    dfflibmap -liberty $(LIBERTY); \
	    abc -liberty $(LIBERTY) -D $(shell echo '$(ABC_PERIOD) * 1000' | bc); \
	    opt_clean; \
	    stat -liberty $(LIBERTY); \
	    write_verilog -noattr $(MAPPED); \
	" 2>&1 | tee $(BUILD)/map.log

.PHONY: area
area: $(MAPPED)
	@echo
	@echo "--- $(CORE) mapped to Nangate45 ---"
	@grep -E 'Chip area|Number of cells' $(BUILD)/map.log | tail -2

.PHONY: area-compare
area-compare:
	@for c in single_cycle pipelined; do \
	    $(MAKE) --no-print-directory CORE=$$c area > /dev/null 2>&1 || \
	        { echo "$$c: FAILED (see synth/build/$$c/map.log)"; continue; }; \
	    cells=$$(grep -E '^\s+Number of cells:' build/$$c/map.log | tail -1 | awk '{print $$4}'); \
	    ar=$$(grep -E 'Chip area' build/$$c/map.log | tail -1 | awk '{print $$NF}'); \
	    printf '%-14s cells %-8s area %s um2\n' "$$c" "$$cells" "$$ar"; \
	done

# ------------------------------------------------------ real timing, in ns
.PHONY: timing
timing: $(MAPPED)
	@command -v sta >/dev/null || { \
	    echo "OpenSTA not found. See synth/README.md for the build."; exit 1; }
	@mkdir -p $(BUILD)
	@printf 'read_liberty %s\n' "$(LIBERTY)"                    > $(BUILD)/sta.tcl
	@printf 'read_verilog %s\n' "$(MAPPED)"                    >> $(BUILD)/sta.tcl
	@printf 'link_design cpu\n'                                >> $(BUILD)/sta.tcl
	@printf 'create_clock -name clk -period %s [get_ports clk]\n' "$(PERIOD)" >> $(BUILD)/sta.tcl
	@printf 'set_input_delay 0 -clock clk [all_inputs -no_clocks]\n'  >> $(BUILD)/sta.tcl
	@printf 'set_output_delay 0 -clock clk [all_outputs]\n'    >> $(BUILD)/sta.tcl
	@printf 'report_checks -path_delay max -digits 3\n'        >> $(BUILD)/sta.tcl
	@printf 'report_wns\nreport_tns\n'                         >> $(BUILD)/sta.tcl
	@printf 'exit\n'                                           >> $(BUILD)/sta.tcl
	sta -no_splash -exit $(BUILD)/sta.tcl 2>&1 | tee $(BUILD)/sta.log

.PHONY: timing-compare
timing-compare:
	@for c in single_cycle pipelined; do \
	    $(MAKE) --no-print-directory CORE=$$c timing > /dev/null 2>&1 || \
	        { echo "$$c: FAILED (see synth/build/$$c/sta.log)"; continue; }; \
	    arr=$$(grep -E 'data arrival time' build/$$c/sta.log | head -1 | awk '{print $$1}'); \
	    fmax=$$(echo "scale=1; 1000 / $$arr" | bc); \
	    printf '%-14s critical path %6s ns   fmax %6s MHz\n' "$$c" "$$arr" "$$fmax"; \
	done

.PHONY: clean
clean:
	rm -rf $(PWD)/build

# The liberty file is a 6.4 MB third-party download; `make clean` leaves it.
.PHONY: distclean
distclean: clean
	rm -rf $(PWD)/pdk
