SHELL := /bin/bash -o pipefail
.SHELLFLAGS += -e

PKG_SRCS := $(PWD)/../pkg/types.sv
HDL_SRCS := $(shell find $(PWD)/../hdl -name '*.sv')

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
