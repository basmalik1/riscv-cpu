SHELL := /bin/bash -o pipefail
.SHELLFLAGS += -e

# Which core to build. Every core exposes the same module name and port list,
# so everything downstream -- testbench, FPGA top, lint -- is unchanged by this.
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
# wildcard, not a bare path: a core with no board top yet is simply absent
# rather than a find error printed on every invocation of this Makefile.
FPGA_DIRS := $(PWD)/../fpga/common $(wildcard $(PWD)/../fpga/$(CORE))
FPGA_SRCS := $(shell find $(FPGA_DIRS) -name '*.sv')
FPGA_HVL  := $(PWD)/../hvl/verilator_fpga/top_tb.sv $(PWD)/../hvl/verilator/verilator_harness.cpp
FPGA_VER_SRCS := $(PKG_SRCS) $(HDL_SRCS) $(FPGA_SRCS) $(FPGA_HVL)

GET_OPTIONS := python3 $(PWD)/../bin/get_options.py
CLOCK       := $(shell $(GET_OPTIONS) clock)
TIMEOUT     := $(shell $(GET_OPTIONS) timeout)
MEM_BASE    := $(shell $(GET_OPTIONS) mem_base)
MEM_SIZE    := $(shell $(GET_OPTIONS) mem_size)

# Only the single-cycle core needs a combinational read, and it needs one
# structurally -- fetch, execute and writeback all happen inside one edge.
# Every other core wants the registered read a real memory gives, so the rule
# is written as an exception rather than a list. Written as a list it silently
# handed the out-of-order core the wrong memory.
SYNC_MEM := $(if $(filter single_cycle,$(CORE)),0,1)

# The single-cycle board top drives the displays from the live fetch PC and is
# the only one that can; anything with instructions in flight has to sample.
# Same shape as SYNC_MEM above, and for the same reason.
LIVE_DISPLAY := $(if $(filter single_cycle,$(CORE)),1,0)

# Per-core build directories, for both paths. Sharing one lets a build from
# the other core look up to date: make finds the binary newer than the
# sources, skips the rebuild, and runs the WRONG CORE while reporting
# entirely plausible numbers. Not hypothetical -- it happened here, and the
# fpga path went on doing it after the simulation path was fixed.
VDIR  := verilator/$(CORE)
FVDIR := fpga/$(CORE)

JOBS := $(shell nproc)

# Optional: fill unwritten memory with a poison word instead of zeros, so a read
# of never-initialised memory (.bss, stack) becomes visible. e.g. MEM_FILL=deadbeef
MEM_FILL ?=
MEM_FILL_ARG := $(if $(MEM_FILL),+MEM_FILL=$(MEM_FILL),)

# Optional: write a commit trace, one line per retired instruction, for
# lockstep against a golden model. Unset costs nothing -- the testbench
# opens no file and the trace task never runs.
COMMITLOG ?=
COMMITLOG_ARG := $(if $(COMMITLOG),+COMMITLOG=$(COMMITLOG),)

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
		$(COMMITLOG_ARG) \
		|& tee simulation.log

# ----------------------------------------------------------------------------
# Golden-model lockstep.
#
# `lockstep` runs the program on the core and on Spike and compares every
# retired instruction. `crosscheck` compares two CORES against each other,
# which needs no Spike at all and is a strong check in its own right: the
# microarchitectures share only the decoder, the ALU and the mdu, so agreeing
# instruction-for-instruction is not something a timing bug survives.
#
# Which two is a parameter, because the useful pair changes. Comparing a new
# core against a known-good one localises a bug to that core immediately, which
# is worth more than the default pair once there are three.
# ----------------------------------------------------------------------------
CROSS_A ?= single_cycle
CROSS_B ?= pipelined

TRACE := $(PWD)/$(VDIR)/commit.log
ELF   := $(PWD)/bin/$(basename $(notdir $(PROG))).elf

.PHONY: trace
# A program that fails does so by spinning until the testbench gives up,
# which is a non-zero exit. That must NOT stop the comparison: a failing
# run is the one whose trace is worth reading, and `where did it first
# diverge` is the whole reason this target exists. Hence the leading `-`.
trace:
	@test -n "$(PROG)" || (echo "Usage: make $@ PROG=../testcode/<test>.s" && false)
	@rm -f $(TRACE)
	-@$(MAKE) --no-print-directory run_verilator_top_tb PROG=$(PROG) COMMITLOG=$(TRACE) > /dev/null 2>&1
	@test -s $(TRACE) || (echo "$(CORE): nothing was traced -- see sim/$(VDIR)/simulation.log" && false)
	@echo "$(CORE): $$(wc -l < $(TRACE)) commits -> $(TRACE)"

.PHONY: lockstep
lockstep: trace
	python3 $(PWD)/../bin/compare_spike.py $(TRACE) $(ELF)

.PHONY: crosscheck
crosscheck:
	@test -n "$(PROG)" || (echo "Usage: make $@ PROG=../testcode/<test>.s" && false)
	@$(MAKE) --no-print-directory CORE=$(CROSS_A) trace PROG=$(PROG)
	@$(MAKE) --no-print-directory CORE=$(CROSS_B) trace PROG=$(PROG)
	python3 $(PWD)/../bin/compare_spike.py --diff \
		$(PWD)/verilator/$(CROSS_A)/commit.log \
		$(PWD)/verilator/$(CROSS_B)/commit.log

# ----------------------------------------------------------------------------
# FPGA path, simulated. Proves fpga/top_de10lite.sv actually carries the core
# before anything reaches a board. The board clock is 50 MHz, so the timeout
# here counts board cycles -- roughly four per instruction.
# ----------------------------------------------------------------------------
$(FVDIR)/build/Vtop_tb: $(FPGA_VER_SRCS) verilator_warn.vlt
	@test -d $(PWD)/../fpga/$(CORE) || (echo "no board top: fpga/$(CORE) does not exist" && false)
	mkdir -p $(FVDIR)/build
	cd $(FVDIR) && verilator $(VER_FLAGS) -GLIVE_DISPLAY=$(LIVE_DISPLAY) $(FPGA_VER_SRCS) --top-module top_tb \
		|& tee build/compile.log
	cd $(FVDIR)/build && $(MAKE) --jobs=$(JOBS) -f Vtop_tb.mk |& tee -a compile.log
	bash check_compile_error.sh $(FVDIR)

.PHONY: run_fpga_sim
run_fpga_sim: $(FVDIR)/build/Vtop_tb $(PROG)
	@test -n "$(PROG)" || (echo "Usage: make $@ PROG=../testcode/<test>.s" && false)
	python3 $(PWD)/../bin/generate_memory_file.py $(PROG)
	cp $(PWD)/bin/memory_32.lst $(FVDIR)/memory_32.lst
	cd $(FVDIR) && ./build/Vtop_tb \
		+CLOCK_PERIOD_PS=20000 \
		+TIMEOUT=$(shell echo $(TIMEOUT) '*' 4 | bc) \
		|& tee simulation.log

# ----------------------------------------------------------------------------
# Unit tests. One self-checking testbench per module, built with --binary so
# each drives its own clock and needs no C++ harness.
#
# Compiled against every core's modules at once regardless of CORE, so that one
# `make unit` covers the whole tree. The stage modules only exist in the
# pipelined core and the out-of-order structures only in ooo; the shared
# modules are the same either way.
#
# The exception is each core's top module. Two files named cpu.sv cannot both
# be elaborated, so the ooo one is excluded and tb_pipeline gets the pipelined
# core it expects. A unit test for the ooo top, when there is one, will need
# its own source list rather than this shared one.
# ----------------------------------------------------------------------------
UNIT_PKG  := $(PWD)/../pkg/types.sv $(PWD)/../pkg/pipelined_types.sv \
             $(wildcard $(PWD)/../pkg/ooo_types.sv)
UNIT_HDL  := $(shell find $(PWD)/../hdl/common $(PWD)/../hdl/pipelined \
                         $(PWD)/../hdl/ooo -name '*.sv' -not -path '*/ooo/cpu.sv')
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

# ----------------------------------------------------------------------------
# Mutation testing. bin/mutate.py breaks a module on purpose and checks its
# testbench notices; see bin/mutations.json for the bugs it injects.
#
# The print-% target below is how that script asks for the source list rather
# than keeping its own copy. Two copies would drift, and the tool would end up
# testing something other than what `make unit` builds.
# ----------------------------------------------------------------------------
.PHONY: print-%
print-%:
	@echo '$($*)'

.PHONY: mutate
mutate:
	python3 $(PWD)/../bin/mutate.py $(if $(MODULE),$(MODULE),--all)

.PHONY: waves
waves:
	gtkwave $(VDIR)/dump.fst

.PHONY: clean
clean:
	# All three are build directories under sim/, not the fpga/ source tree.
	rm -rf $(PWD)/bin $(PWD)/verilator $(PWD)/fpga $(PWD)/unit
