SHELL := /bin/bash -o pipefail
.SHELLFLAGS += -e

# Which core to build. Both expose the same module name and port list, so
# everything downstream -- testbench, FPGA top, lint -- is unchanged by this.
CORE ?= single_cycle

# The shared package first, then any package belonging to the selected core.
# Order matters: a package must be compiled before the modules that import it.
PKG_SRCS := $(PWD)/../pkg/types.sv $(wildcard $(PWD)/../pkg/$(CORE)_types.sv)
HDL_SRCS := $(shell find $(PWD)/../hdl/common $(PWD)/../hdl/$(CORE) -name '*.sv')
VER_HVL  := $(shell find $(PWD)/../hvl/common $(PWD)/../hvl/verilator \
                        -name '*.sv' -o -name '*.cpp')
HDRS     := $(shell find $(PWD)/../hvl -name '*.svh')
VER_SRCS := $(PKG_SRCS) $(HDL_SRCS) $(VER_HVL)

# FPGA build: the same core and pkg, but with the synthesizable memory and
# board top from fpga/ instead of the behavioural model in hvl/common.
# Same split as hdl/: shared board logic in fpga/common, the board top for
# the selected core beside it. The single-cycle top needs a phase counter to
# divide the clock; the pipelined one does not, which is the whole point.
FPGA_SRCS := $(shell find $(PWD)/../fpga/common $(PWD)/../fpga/$(CORE) -name '*.sv')
FPGA_HVL  := $(PWD)/../hvl/verilator_fpga/top_tb.sv $(PWD)/../hvl/verilator/verilator_harness.cpp
FPGA_VER_SRCS := $(PKG_SRCS) $(HDL_SRCS) $(FPGA_SRCS) $(FPGA_HVL)

GET_OPTIONS := python3 $(PWD)/../bin/get_options.py
CLOCK       := $(shell $(GET_OPTIONS) clock)
TIMEOUT     := $(shell $(GET_OPTIONS) timeout)
MEM_BASE    := $(shell $(GET_OPTIONS) mem_base)
MEM_SIZE    := $(shell $(GET_OPTIONS) mem_size)

# The pipelined core expects a registered memory read; the single-cycle core
# expects a combinational one. Selecting the core selects the memory model.
SYNC_MEM := $(if $(filter pipelined,$(CORE)),1,0)

# The single-cycle board top drives the displays from the live fetch PC; the
# pipelined one samples them. Only the former can be checked against the PC.
LIVE_DISPLAY := $(if $(filter pipelined,$(CORE)),0,1)

VDIR := verilator/$(CORE)

JOBS := $(shell nproc)

# Optional: fill unwritten memory with a poison word instead of zeros, so a read
# of never-initialised memory (.bss, stack) becomes visible. e.g. MEM_FILL=deadbeef
MEM_FILL ?=
MEM_FILL_ARG := $(if $(MEM_FILL),+MEM_FILL=$(MEM_FILL),)

# Verilator's default --trace-max-array of 32 is deliberate here: it keeps the
# 32-entry register file in the waveform while leaving the 16384-word memory
# out. Raising it drags every memory word in as its own signal, which is ~16k
# signals and makes GTKWave's signal browser unusable. Read memory contents from
# sim/bin/memory_32.lst and the .dis instead.
VER_FLAGS = -Wall --timescale 1ps/1ps -Mdir build -O3 -CFLAGS "-O2" \
            --x-assign fast --x-initial fast --cc --exe \
            --trace-fst --trace-structs \
            +incdir+$(PWD)/../hvl/common \
            -GMEM_BASE=$(MEM_BASE) -GMEM_SIZE=$(MEM_SIZE) \
            $(PWD)/verilator_warn.vlt

$(VDIR)/build/Vtop_tb: $(VER_SRCS) $(HDRS) verilator_warn.vlt
	mkdir -p $(VDIR)/build
	cd $(VDIR) && verilator $(VER_FLAGS) -GSYNC_MEM=$(SYNC_MEM) $(VER_SRCS) --top-module top_tb \
		|& tee build/compile.log
	cd $(VDIR)/build && $(MAKE) --jobs=$(JOBS) -f Vtop_tb.mk |& tee -a compile.log
	bash check_compile_error.sh $(VDIR)

.PHONY: run_verilator_top_tb
run_verilator_top_tb: $(VDIR)/build/Vtop_tb $(PROG)
	@test -n "$(PROG)" || (echo "Usage: make $@ PROG=../testcode/<test>.s" && false)
	python3 $(PWD)/../bin/generate_memory_file.py $(PROG)
	cd $(VDIR) && ./build/Vtop_tb \
		+CLOCK_PERIOD_PS=$(CLOCK) \
		+TIMEOUT=$(TIMEOUT) \
		+MEMLST=$(PWD)/bin/memory_32.lst \
		$(MEM_FILL_ARG) \
		|& tee simulation.log

# ----------------------------------------------------------------------------
# FPGA path, simulated. Proves fpga/top_de10lite.sv actually carries the core
# before anything reaches a board. The board clock is 50 MHz, so the timeout
# here counts board cycles -- roughly four per instruction.
# ----------------------------------------------------------------------------
fpga/build/Vtop_tb: $(FPGA_VER_SRCS) verilator_warn.vlt
	mkdir -p fpga/build
	cd fpga && verilator $(VER_FLAGS) -GLIVE_DISPLAY=$(LIVE_DISPLAY) $(FPGA_VER_SRCS) --top-module top_tb \
		|& tee build/compile.log
	cd fpga/build && $(MAKE) --jobs=$(JOBS) -f Vtop_tb.mk |& tee -a compile.log
	bash check_compile_error.sh fpga

.PHONY: run_fpga_sim
run_fpga_sim: fpga/build/Vtop_tb $(PROG)
	@test -n "$(PROG)" || (echo "Usage: make $@ PROG=../testcode/<test>.s" && false)
	python3 $(PWD)/../bin/generate_memory_file.py $(PROG)
	cp $(PWD)/bin/memory_32.lst fpga/memory_32.lst
	cd fpga && ./build/Vtop_tb \
		+CLOCK_PERIOD_PS=20000 \
		+TIMEOUT=$(shell echo $(TIMEOUT) '*' 4 | bc) \
		|& tee simulation.log

# ----------------------------------------------------------------------------
# Unit tests. One self-checking testbench per module, built with --binary so
# each drives its own clock and needs no C++ harness.
#
# Always compiled against hdl/common + hdl/pipelined regardless of CORE: the
# stage modules only exist in the pipelined core, and the shared modules are
# the same either way.
# ----------------------------------------------------------------------------
UNIT_PKG  := $(PWD)/../pkg/types.sv $(PWD)/../pkg/pipelined_types.sv
UNIT_HDL  := $(shell find $(PWD)/../hdl/common $(PWD)/../hdl/pipelined -name '*.sv')
UNIT_TBS  := $(sort $(wildcard $(PWD)/../hvl/unit/tb_*.sv))

UNIT_FLAGS = --binary --timing -Wall --timescale 1ps/1ps \
             +incdir+$(PWD)/../hvl/unit \
             $(PWD)/verilator_warn.vlt

.PHONY: unit
unit:
	@fail=0; pass=0; \
	for tb in $(UNIT_TBS); do \
	    name=$$(basename $$tb .sv); \
	    mkdir -p unit/$$name; \
	    if ! verilator $(UNIT_FLAGS) -Mdir unit/$$name/obj \
	            $(UNIT_PKG) $(UNIT_HDL) $$tb \
	            --top-module $$name -o $$name \
	            > unit/$$name/build.log 2>&1; then \
	        echo "BUILD FAIL $$name (see sim/unit/$$name/build.log)"; \
	        fail=$$((fail+1)); continue; \
	    fi; \
	    if ./unit/$$name/obj/$$name > unit/$$name/run.log 2>&1; then \
	        grep -h '^PASS' unit/$$name/run.log; pass=$$((pass+1)); \
	    else \
	        grep -hE '^(FAIL|  FAIL)' unit/$$name/run.log || echo "FAIL $$name"; \
	        fail=$$((fail+1)); \
	    fi; \
	done; \
	echo ""; \
	if [ $$fail -ne 0 ]; then \
	    echo -e "\033[0;31m$$fail unit test(s) failed, $$pass passed\033[0m"; exit 1; \
	else \
	    echo -e "\033[0;32mall $$pass unit tests passed\033[0m"; \
	fi

.PHONY: waves
waves:
	gtkwave $(VDIR)/dump.fst

.PHONY: clean
clean:
	# All three are build directories under sim/, not the fpga/ source tree.
	rm -rf $(PWD)/bin $(PWD)/verilator $(PWD)/fpga $(PWD)/unit
