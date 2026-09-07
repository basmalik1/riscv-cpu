// stage_wb: load extension and the writeback mux.
//
// The word 0x89abcdef is used throughout because every byte of it has its top
// bit set, so a missing sign extension is visible in every lane rather than
// only in the ones that happen to be negative.

module tb_stage_wb
import rv32i_types::*;
import pipelined_types::*;
;

    `include "tb_check.svh"

    mem_wb_t     mem_wb;
    logic [31:0] dmem_rdata;
    logic [31:0] wb_value;
    logic [4:0]  rd_s;
    logic        regf_we, halt, commit;

    stage_wb dut (.*);

    task automatic load(logic [2:0] f3, logic [1:0] off);
        mem_wb          = '0;
        mem_wb.valid    = 1'b1;
        mem_wb.regf_we  = 1'b1;
        mem_wb.wb_sel   = wb_mem;
        mem_wb.funct3   = f3;
        mem_wb.byte_off = off;
        dmem_rdata      = 32'h89ab_cdef;
    endtask

    initial begin
        // ---- lb: sign extended from the addressed byte -------------------
        load(3'b000, 2'd0); #1; expect_eq("lb off 0", wb_value, 32'hffff_ffef);
        load(3'b000, 2'd1); #1; expect_eq("lb off 1", wb_value, 32'hffff_ffcd);
        load(3'b000, 2'd2); #1; expect_eq("lb off 2", wb_value, 32'hffff_ffab);
        load(3'b000, 2'd3); #1; expect_eq("lb off 3", wb_value, 32'hffff_ff89);

        // ---- lbu: zero extended, same lanes ------------------------------
        load(3'b100, 2'd0); #1; expect_eq("lbu off 0", wb_value, 32'h0000_00ef);
        load(3'b100, 2'd3); #1; expect_eq("lbu off 3", wb_value, 32'h0000_0089);

        // ---- lh / lhu ----------------------------------------------------
        load(3'b001, 2'd0); #1; expect_eq("lh off 0",  wb_value, 32'hffff_cdef);
        load(3'b001, 2'd2); #1; expect_eq("lh off 2",  wb_value, 32'hffff_89ab);
        load(3'b101, 2'd0); #1; expect_eq("lhu off 0", wb_value, 32'h0000_cdef);
        load(3'b101, 2'd2); #1; expect_eq("lhu off 2", wb_value, 32'h0000_89ab);

        // ---- lw takes the whole word untouched ---------------------------
        load(3'b010, 2'd0); #1; expect_eq("lw", wb_value, 32'h89ab_cdef);

        // ---- a positive byte must NOT get sign extended -------------------
        load(3'b000, 2'd0);
        dmem_rdata = 32'h0000_007f; #1;
        expect_eq("lb positive", wb_value, 32'h0000_007f);

        // ---- writeback mux -----------------------------------------------
        mem_wb         = '0;
        mem_wb.valid   = 1'b1;
        mem_wb.regf_we = 1'b1;
        mem_wb.alu_f   = 32'h1111_1111;
        mem_wb.pc4     = 32'h2222_2222;
        mem_wb.imm     = 32'h3333_3333;

        mem_wb.wb_sel = wb_alu; #1; expect_eq("wb alu", wb_value, 32'h1111_1111);
        mem_wb.wb_sel = wb_pc4; #1; expect_eq("wb pc4", wb_value, 32'h2222_2222);
        mem_wb.wb_sel = wb_imm; #1; expect_eq("wb imm", wb_value, 32'h3333_3333);

        // ---- a bubble retires nothing and writes nothing ------------------
        mem_wb         = '0;
        mem_wb.valid   = 1'b0;
        mem_wb.regf_we = 1'b1;
        mem_wb.is_halt = 1'b1;
        #1;
        expect_bit("bubble does not write",  regf_we, 1'b0);
        expect_bit("bubble does not commit", commit,  1'b0);
        // A squashed halt must not stop the machine: an instruction two past a
        // taken branch is fetched, then thrown away.
        expect_bit("squashed halt ignored",  halt,    1'b0);

        mem_wb.valid = 1'b1; #1;
        expect_bit("valid halt reported",    halt,    1'b1);
        expect_bit("valid commit reported",  commit,  1'b1);

        report("stage_wb");
    end

endmodule
