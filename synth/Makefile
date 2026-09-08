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

# Every directory under hdl/ except common is a core. Derived rather than
# listed, so the comparison targets below pick up a new one without being
# edited -- which is what three hardcoded copies of the old list did not.
CORES := $(filter-out common,$(notdir $(wildcard $(PWD)/../hdl/*)))

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
	@for c in $(CORES); do \
	    $(MAKE) --no-print-directory CORE=$$c synth > /dev/null 2>&1 || \
	        { echo "$$c: FAILED (see synth/build/$$c/synth.log)"; continue; }; \
	    cells=$$(grep -E '^\s+Number of cells:' build/$$c/synth.log | tail -1 | awk '{print $$4}'); \
	    ltp=$$(grep -E 'Longest topological path in cpu' build/$$c/synth.log | tail -1 | grep -oE 'length=[0-9]+' | cut -d= -f2); \
	    printf '%-14s cells %-8s logic depth %s\n' "$$c" "$$cells" "$$ltp"; \
	done

# ------------------------------------------- mapped to real standard cells
# abc.script is yosys's own default liberty script with a buffering and
# resizing tail; see the file. Yosys substitutes {D} only in the inline
# (-script +...) form, and that form cannot carry semicolons through `-p`, so
# the target is substituted here instead.
ABC_PS     := $(shell echo '$(ABC_PERIOD) * 1000' | bc)
ABC_SCRIPT := $(BUILD)/abc.script

$(ABC_SCRIPT): abc.script
	mkdir -p $(BUILD)
	sed 's/{D}/$(ABC_PS)/g' $< > $@

$(MAPPED): $(FLAT) $(LIBERTY) $(ABC_SCRIPT)
	yosys -p " \
	    read_verilog $(FLAT); \
	    hierarchy -check -top cpu; \
	    synth -top cpu -flatten; \
	    dfflibmap -liberty $(LIBERTY); \
	    abc -liberty $(LIBERTY) -D $(ABC_PS) -script $(ABC_SCRIPT); \
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
	@for c in $(CORES); do \
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
	@for c in $(CORES); do \
	    $(MAKE) --no-print-directory CORE=$$c timing > /dev/null 2>&1 || \
	        { echo "$$c: FAILED (see synth/build/$$c/sta.log)"; continue; }; \
	    arr=$$(grep -E 'data arrival time' build/$$c/sta.log | head -1 | awk '{print $$1}'); \
	    fmax=$$(echo "scale=1; 1000 / $$arr" | bc); \
	    printf '%-14s critical path %6s ns   fmax %6s MHz\n' "$$c" "$$arr" "$$fmax"; \
	done

# -------------------------------------------- the artifact-free lower bound
# `buffer` in abc.script builds fanout trees inside the combinational logic,
# but flip-flops belong to yosys rather than ABC, so a REGISTERED signal that
# fans out to a thousand gates still carries its whole load on one DFF_X1.
# Closing that needs OpenROAD's `repair_design`; see README.
#
# Until then the size of the remaining hole is measurable rather than
# guessable. Cut every path through a net wider than FANOUT_CUT and report the
# worst path that is left. Nothing on it is charged a load the flow failed to
# buffer, so it is a genuine delay the design has to pay -- a LOWER BOUND on
# the critical path, and on two of the three cores it comes back equal to the
# reported one, which says the reported one was already real.
FANOUT_CUT ?= 64

.PHONY: timing-bound
timing-bound: $(MAPPED)
	@command -v sta >/dev/null || { \
	    echo "OpenSTA not found. See synth/README.md for the build."; exit 1; }
	@mkdir -p $(BUILD)
	@printf 'read_liberty %s\n' "$(LIBERTY)"                    > $(BUILD)/bound.tcl
	@printf 'read_verilog %s\n' "$(MAPPED)"                    >> $(BUILD)/bound.tcl
	@printf 'link_design cpu\n'                                >> $(BUILD)/bound.tcl
	@printf 'create_clock -name clk -period %s [get_ports clk]\n' "$(PERIOD)" >> $(BUILD)/bound.tcl
	@printf 'set_input_delay 0 -clock clk [all_inputs -no_clocks]\n'  >> $(BUILD)/bound.tcl
	@printf 'set_output_delay 0 -clock clk [all_outputs]\n'    >> $(BUILD)/bound.tcl
	@printf 'set cut 0\n'                                      >> $(BUILD)/bound.tcl
	@printf 'foreach net [get_nets *] {\n'                     >> $(BUILD)/bound.tcl
	@printf '  if {[llength [get_pins -of_objects $$net]] > %s} {\n' "$(FANOUT_CUT)" >> $(BUILD)/bound.tcl
	@printf '    set_false_path -through $$net\n'              >> $(BUILD)/bound.tcl
	@printf '    incr cut\n  }\n}\n'                           >> $(BUILD)/bound.tcl
	@printf 'puts "nets wider than %s, cut: $$cut"\n' "$(FANOUT_CUT)" >> $(BUILD)/bound.tcl
	@printf 'report_checks -path_delay max -digits 3 -fields {fanout}\n' >> $(BUILD)/bound.tcl
	@printf 'exit\n'                                           >> $(BUILD)/bound.tcl
	sta -no_splash -exit $(BUILD)/bound.tcl 2>&1 | tee $(BUILD)/bound.log

.PHONY: bound-compare
bound-compare:
	@for c in $(CORES); do \
	    $(MAKE) --no-print-directory CORE=$$c timing         > /dev/null 2>&1 || \
	        { echo "$$c: FAILED (see synth/build/$$c/sta.log)"; continue; }; \
	    $(MAKE) --no-print-directory CORE=$$c timing-bound   > /dev/null 2>&1 || \
	        { echo "$$c: FAILED (see synth/build/$$c/bound.log)"; continue; }; \
	    arr=$$(grep -a 'data arrival time' build/$$c/sta.log   | head -1 | awk '{print $$1}'); \
	    bnd=$$(grep -a 'data arrival time' build/$$c/bound.log | head -1 | awk '{print $$1}'); \
	    cut=$$(grep -a 'cut:' build/$$c/bound.log | tail -1 | awk '{print $$NF}'); \
	    printf '%-14s reported %7s ns   artifact-free %7s ns   (%s wide nets)\n' \
	        "$$c" "$$arr" "$$bnd" "$$cut"; \
	done

.PHONY: clean
clean:
	rm -rf $(PWD)/build

# The liberty file is a 6.4 MB third-party download; `make clean` leaves it.
.PHONY: distclean
distclean: clean
	rm -rf $(PWD)/pdk
