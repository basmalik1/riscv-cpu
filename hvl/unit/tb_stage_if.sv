// stage_if: the program counter and the instruction replay.
//
// The replay case is the one that matters. Holding the PC does not hold the
// instruction when the memory read is registered, and getting that wrong
// issues the stalled instruction twice -- which is exactly what happened
// during bring-up. The test drives a changing imem_rdata during a stall so a
// re-fetch would be visible.

module tb_stage_if
import rv32i_types::*;
import pipelined_types::*;
;

    `include "tb_check.svh"

    localparam bit [31:0] RESET_PC = 32'h8000_0000;

    logic        clk = 1'b0;
    logic        rst;
    logic        stall, redirect;
    logic [31:0] redirect_pc;
    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] inst;
    if_id_t      if_id_n;

    always #5 clk = ~clk;

    stage_if #(.RESET_PC(RESET_PC)) dut (.*);

    initial begin
        rst         = 1'b1;
        stall       = 1'b0;
        redirect    = 1'b0;
        redirect_pc = '0;
        imem_rdata  = 32'h0000_0000;

        @(negedge clk);
        #1;
        expect_eq("reset pc", imem_addr, RESET_PC);

        @(negedge clk);
        rst = 1'b0;
        #1;
        expect_eq("still at reset pc", imem_addr, RESET_PC);

        // ---- free running: +4 every cycle --------------------------------
        @(negedge clk); #1;
        expect_eq("pc + 4",  imem_addr, RESET_PC + 32'd4);
        @(negedge clk); #1;
        expect_eq("pc + 8",  imem_addr, RESET_PC + 32'd8);
        expect_eq("if_id_n carries pc", if_id_n.pc, RESET_PC + 32'd8);
        expect_bit("if_id_n valid",     if_id_n.valid, 1'b1);

        // ---- redirect wins over the increment -----------------------------
        redirect    = 1'b1;
        redirect_pc = 32'h8000_1000;
        @(negedge clk);
        redirect = 1'b0;
        #1;
        expect_eq("redirect takes effect", imem_addr, 32'h8000_1000);

        @(negedge clk); #1;
        expect_eq("resumes from target", imem_addr, 32'h8000_1004);

        // ---- stall holds the PC -------------------------------------------
        stall = 1'b1;
        @(negedge clk); #1;
        expect_eq("stall holds pc", imem_addr, 32'h8000_1004);
        @(negedge clk); #1;
        expect_eq("stall still holds", imem_addr, 32'h8000_1004);
        stall = 1'b0;
        @(negedge clk); #1;
        expect_eq("advances after stall", imem_addr, 32'h8000_1008);

        // ---- the replay, which is the whole reason held_inst exists --------
        // Present an instruction, then stall while the memory returns
        // something else. A correct fetch replays the first one; a re-fetch
        // would surface the second.
        imem_rdata = 32'h1111_1111;
        @(negedge clk); #1;
        expect_eq("inst passes through", inst, 32'h1111_1111);

        stall = 1'b1;
        #1;
        expect_eq("inst held on first stall cycle", inst, 32'h1111_1111);

        @(negedge clk);
        imem_rdata = 32'h2222_2222;     // memory has moved on
        #1;
        expect_eq("stalled inst replayed", inst, 32'h1111_1111);

        @(negedge clk);
        imem_rdata = 32'h3333_3333;
        #1;
        expect_eq("still replaying", inst, 32'h1111_1111);

        stall = 1'b0;
        @(negedge clk);
        imem_rdata = 32'h4444_4444;
        #1;
        expect_eq("resumes live memory", inst, 32'h4444_4444);

        // ---- a redirect during a stall drops the held instruction ---------
        imem_rdata = 32'h5555_5555;
        @(negedge clk); #1;
        stall = 1'b1;
        @(negedge clk);
        redirect    = 1'b1;
        redirect_pc = 32'h8000_2000;
        @(negedge clk);
        redirect = 1'b0;
        stall    = 1'b0;
        imem_rdata = 32'h6666_6666;
        #1;
        expect_eq("redirect clears held", inst, 32'h6666_6666);
        expect_eq("redirect pc applied",  imem_addr, 32'h8000_2000);

        report("stage_if");
    end

endmodule
