// stage_mem: byte masks and lane shifting.
//
// This is where sub-word accesses live, and the memory model asserts that an
// illegal mask is a misaligned access -- so a wrong mask here is a wrong
// program, not just a wrong byte.

module tb_stage_mem
import rv32i_types::*;
import pipelined_types::*;
;

    `include "tb_check.svh"

    ex_mem_t     ex_mem;
    logic [31:0] dmem_addr, dmem_wdata;
    logic [3:0]  dmem_rmask, dmem_wmask;
    logic [31:0] fwd_value;
    mem_wb_t     mem_wb;

    stage_mem dut (.*);

    task automatic setup();
        ex_mem            = '0;
        ex_mem.valid      = 1'b1;
        ex_mem.rd_s       = 5'd1;
        ex_mem.wb_sel     = wb_alu;
    endtask

    initial begin
        // ---- addresses are always word aligned --------------------------
        setup();
        ex_mem.alu_f = 32'h8000_0007;
        #1;
        expect_eq("addr word aligned", dmem_addr, 32'h8000_0004);

        // ---- load masks at every byte offset ----------------------------
        setup();
        ex_mem.mem_read = 1'b1;
        ex_mem.funct3   = 3'b000;               // byte
        ex_mem.alu_f    = 32'h8000_0000; #1;
        expect_eq("lb mask offset 0", {28'd0, dmem_rmask}, 32'b0001);
        ex_mem.alu_f    = 32'h8000_0001; #1;
        expect_eq("lb mask offset 1", {28'd0, dmem_rmask}, 32'b0010);
        ex_mem.alu_f    = 32'h8000_0002; #1;
        expect_eq("lb mask offset 2", {28'd0, dmem_rmask}, 32'b0100);
        ex_mem.alu_f    = 32'h8000_0003; #1;
        expect_eq("lb mask offset 3", {28'd0, dmem_rmask}, 32'b1000);

        ex_mem.funct3   = 3'b001;               // halfword
        ex_mem.alu_f    = 32'h8000_0000; #1;
        expect_eq("lh mask offset 0", {28'd0, dmem_rmask}, 32'b0011);
        ex_mem.alu_f    = 32'h8000_0002; #1;
        expect_eq("lh mask offset 2", {28'd0, dmem_rmask}, 32'b1100);

        ex_mem.funct3   = 3'b010;               // word
        ex_mem.alu_f    = 32'h8000_0000; #1;
        expect_eq("lw mask",          {28'd0, dmem_rmask}, 32'b1111);

        // lbu and lhu share the width encoding with lb and lh.
        ex_mem.funct3   = 3'b100;               // lbu
        ex_mem.alu_f    = 32'h8000_0002; #1;
        expect_eq("lbu mask offset 2", {28'd0, dmem_rmask}, 32'b0100);
        ex_mem.funct3   = 3'b101;               // lhu
        ex_mem.alu_f    = 32'h8000_0002; #1;
        expect_eq("lhu mask offset 2", {28'd0, dmem_rmask}, 32'b1100);

        // ---- store masks and data lane ----------------------------------
        setup();
        ex_mem.mem_write = 1'b1;
        ex_mem.store_data = 32'h0000_00aa;
        ex_mem.funct3    = 3'b000;
        ex_mem.alu_f     = 32'h8000_0002; #1;
        expect_eq("sb mask offset 2",  {28'd0, dmem_wmask}, 32'b0100);
        expect_eq("sb data shifted",   dmem_wdata, 32'h00aa_0000);

        ex_mem.store_data = 32'h0000_beef;
        ex_mem.funct3     = 3'b001;
        ex_mem.alu_f      = 32'h8000_0002; #1;
        expect_eq("sh mask offset 2",  {28'd0, dmem_wmask}, 32'b1100);
        expect_eq("sh data shifted",   dmem_wdata, 32'hbeef_0000);

        // ---- a bubble must not touch memory -----------------------------
        setup();
        ex_mem.valid     = 1'b0;
        ex_mem.mem_read  = 1'b1;
        ex_mem.mem_write = 1'b1;
        ex_mem.funct3    = 3'b010;
        #1;
        expect_eq("bubble reads nothing",  {28'd0, dmem_rmask}, 32'd0);
        expect_eq("bubble writes nothing", {28'd0, dmem_wmask}, 32'd0);

        // ---- what MEM offers the forwarding network ---------------------
        setup();
        ex_mem.alu_f  = 32'h1111_1111;
        ex_mem.pc4    = 32'h2222_2222;
        ex_mem.imm    = 32'h3333_3333;
        ex_mem.wb_sel = wb_alu; #1;
        expect_eq("fwd from alu", fwd_value, 32'h1111_1111);
        ex_mem.wb_sel = wb_pc4;  #1;
        expect_eq("fwd from pc4", fwd_value, 32'h2222_2222);
        ex_mem.wb_sel = wb_imm;  #1;
        expect_eq("fwd from imm", fwd_value, 32'h3333_3333);
        // A load has no value yet; hazard.sv is what stops this being used.
        ex_mem.wb_sel = wb_mem;  #1;
        expect_eq("fwd for load is 0", fwd_value, 32'd0);

        report("stage_mem");
    end

endmodule
