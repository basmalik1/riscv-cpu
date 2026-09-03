#include <climits>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>

#include <verilated.h>
#include <verilated_fst_c.h>

#include "Vtop_tb.h"

using namespace std;

static uint64_t clk_half_period = 0;

static void tick(const unique_ptr<VerilatedContext>& ctx,
                 const unique_ptr<Vtop_tb>& top,
                 const unique_ptr<VerilatedFstC>& tfp) {
    ctx->timeInc(clk_half_period);
    top->clk = !top->clk;
    top->eval();
    tfp->dump(ctx->time());
}

static void tick_cycles(const unique_ptr<VerilatedContext>& ctx,
                        const unique_ptr<Vtop_tb>& top,
                        const unique_ptr<VerilatedFstC>& tfp,
                        int cycles) {
    for (int i = 0; i < cycles * 2; i++) {
        tick(ctx, top, tfp);
    }
}

static uint64_t get_int_plusarg(const unique_ptr<VerilatedContext>& ctx,
                                const string& arg) {
    string s(ctx->commandArgsPlusMatch(arg.c_str()));
    if (s.empty()) {
        cerr << "TB Error: missing +" << arg << endl;
        exit(EXIT_FAILURE);
    }
    replace(s.begin(), s.end(), '=', ' ');
    stringstream ss(s);
    string name;
    uint64_t value;
    ss >> name >> value;
    return value;
}

int main(int argc, char** argv) {
    const unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    ctx->traceEverOn(true);
    ctx->commandArgs(argc, argv);
    ctx->fatalOnError(false);

    clk_half_period = get_int_plusarg(ctx, "CLOCK_PERIOD_PS") / 2;

    const unique_ptr<Vtop_tb> top{new Vtop_tb{ctx.get(), "top"}};
    const unique_ptr<VerilatedFstC> tfp{new VerilatedFstC};

    top->trace(tfp.get(), INT_MAX);
    tfp->open("dump.fst");

    top->clk = 1;
    top->rst = 1;
    tick_cycles(ctx, top, tfp, 2);

    top->rst = 0;
    while (!ctx->gotFinish()) {
        tick_cycles(ctx, top, tfp, 1);
    }

    tfp->close();
    top->final();
    return ctx->gotError() ? EXIT_FAILURE : EXIT_SUCCESS;
}
