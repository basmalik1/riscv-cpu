SHELL := /bin/bash -o pipefail
.SHELLFLAGS += -e

PKG_SRCS := $(PWD)/../pkg/types.sv
HDL_SRCS := $(shell find $(PWD)/../hdl -name '*.sv')
VER_HVL  := $(shell find $(PWD)/../hvl/common $(PWD)/../hvl/verilator \
                        -name '*.sv' -o -name '*.cpp')
HDRS     := $(shell find $(PWD)/../hvl -name '*.svh')
VER_SRCS := $(PKG_SRCS) $(HDL_SRCS) $(VER_HVL)

GET_OPTIONS := python3 $(PWD)/../bin/get_options.py
CLOCK       := $(shell $(GET_OPTIONS) clock)
TIMEOUT     := $(shell $(GET_OPTIONS) timeout)
MEM_BASE    := $(shell $(GET_OPTIONS) mem_base)
MEM_SIZE    := $(shell $(GET_OPTIONS) mem_size)

JOBS := $(shell nproc)

# Optional: fill unwritten memory with a poison word instead of zeros, so a read
# of never-initialised memory (.bss, stack) becomes visible. e.g. MEM_FILL=deadbeef
MEM_FILL ?=
MEM_FILL_ARG := $(if $(MEM_FILL),+MEM_FILL=$(MEM_FILL),)

VER_FLAGS = -Wall --timescale 1ps/1ps -Mdir build -O3 -CFLAGS "-O2" \
            --x-assign fast --x-initial fast --cc --exe \
            --trace-fst --trace-structs --trace-max-array 1048576 \
            +incdir+$(PWD)/../hvl/common \
            -GMEM_BASE=$(MEM_BASE) -GMEM_SIZE=$(MEM_SIZE) \
            $(PWD)/verilator_warn.vlt

verilator/build/Vtop_tb: $(VER_SRCS) $(HDRS) verilator_warn.vlt
	mkdir -p verilator/build
	cd verilator && verilator $(VER_FLAGS) $(VER_SRCS) --top-module top_tb \
		|& tee build/compile.log
	cd verilator/build && $(MAKE) --jobs=$(JOBS) -f Vtop_tb.mk |& tee -a compile.log
	bash check_compile_error.sh

.PHONY: run_verilator_top_tb
run_verilator_top_tb: verilator/build/Vtop_tb $(PROG)
	@test -n "$(PROG)" || (echo "Usage: make $@ PROG=../testcode/<test>.s" && false)
	python3 $(PWD)/../bin/generate_memory_file.py $(PROG)
	cd verilator && ./build/Vtop_tb \
		+CLOCK_PERIOD_PS=$(CLOCK) \
		+TIMEOUT=$(TIMEOUT) \
		+MEMLST=$(PWD)/bin/memory_32.lst \
		$(MEM_FILL_ARG) \
		|& tee simulation.log

.PHONY: waves
waves:
	gtkwave verilator/dump.fst

.PHONY: clean
clean:
	rm -rf bin verilator
