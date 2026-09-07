SHELL := /bin/bash -o pipefail
.SHELLFLAGS += -e

# Which core to build. Both expose the same module name and port list, so
# everything downstream -- testbench, FPGA top, lint -- is unchanged by this.
CORE ?= single_cycle

# The shared package first, then any package belonging to the selected core.
# Order matters: a package must be compiled before the modules that import it.
PKG_SRCS := $(PWD)/../pkg/types.sv $(wildcard $(PWD)/../pkg/$(CORE)_types.sv)
HDL_SRCS := $(shell find $(PWD)/../hdl/common $(PWD)/../hdl/$(CORE) -name '*.sv')

LINT_FLAGS = --lint-only -Wall --timescale 1ps/1ps \
             $(PWD)/../sim/verilator_warn.vlt

.PHONY: lint
lint:
	verilator $(LINT_FLAGS) $(PKG_SRCS) $(HDL_SRCS) --top-module cpu \
		|& tee lint.log
	@echo -e "\033[0;32mLint clean \033[0m"

.PHONY: clean
clean:
	rm -f lint.log
