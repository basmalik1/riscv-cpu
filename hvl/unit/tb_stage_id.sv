// stage_id: immediate assembly, which is the fiddliest thing in the stage.
//
// The five formats scatter their bits differently and every one of them sign
// extends from inst[31]. Getting a field boundary wrong produces an immediate
// that is right for small positive values and wrong everywhere else, so the
// negative cases here matter more than the positive ones.

module tb_stage_id
import rv32i_types::*;
import pipelined_types::*;
;

    `include "tb_check.svh"

    if_id_t      if_id;
    logic [31:0] inst;
    logic [31:0] rs1_v, rs2_v;
    logic [4:0]  rs1_s, rs2_s;
    rv32i_opcode opcode;
    id_ex_t      id_ex;

    stage_id dut (.*);

    initial begin
        if_id.valid = 1'b1;
        if_id.pc    = 32'h8000_0100;
        rs1_v       = 32'haaaa_aaaa;
        rs2_v       = 32'hbbbb_bbbb;

        // ---- I type ----------------------------------------------------
        inst = 32'h00510093;            // addi x1, x2, 5
        #1;
        expect_eq ("I imm positive", id_ex.imm, 32'd5);
        expect_eq ("rs1_s field",    {27'd0, rs1_s}, 32'd2);
        expect_eq ("rd_s field",     {27'd0, id_ex.rd_s}, 32'd1);

        inst = 32'hfff10093;            // addi x1, x2, -1
        #1;
        expect_eq ("I imm negative", id_ex.imm, 32'hffff_ffff);

        inst = 32'h80010093;            // addi x1, x2, -2048, the extreme
        #1;
        expect_eq ("I imm min",      id_ex.imm, 32'hffff_f800);

        // ---- S type: the immediate is split across two fields -----------
        inst = 32'h00312023;            // sw x3, 0(x2)
        #1;
        expect_eq ("S imm zero",     id_ex.imm, 32'd0);

        inst = 32'h00312fa3;            // sw x3, 31(x2)
        #1;
        expect_eq ("S imm 31",       id_ex.imm, 32'd31);

        inst = 32'hfe312e23;            // sw x3, -4(x2)
        #1;
        expect_eq ("S imm negative",  id_ex.imm, 32'hffff_fffc);

        // ---- B type: bit 0 is always zero, bit 11 comes from inst[7] ----
        inst = 32'h00208463;            // beq x1, x2, +8
        #1;
        expect_eq ("B imm +8",       id_ex.imm, 32'd8);

        inst = 32'hfe208ee3;            // beq x1, x2, -4
        #1;
        expect_eq ("B imm -4",       id_ex.imm, 32'hffff_fffc);

        // ---- U type: no sign extension, low 12 bits are zero ------------
        inst = 32'h123450b7;            // lui x1, 0x12345
        #1;
        expect_eq ("U imm",          id_ex.imm, 32'h1234_5000);

        inst = 32'hfffff0b7;            // lui x1, 0xfffff
        #1;
        expect_eq ("U imm high",     id_ex.imm, 32'hffff_f000);

        // ---- J type: the most scrambled of the five ---------------------
        inst = 32'h008000ef;            // jal x1, +8
        #1;
        expect_eq ("J imm +8",       id_ex.imm, 32'd8);

        inst = 32'hffdff0ef;            // jal x1, -4
        #1;
        expect_eq ("J imm -4",       id_ex.imm, 32'hffff_fffc);

        // ---- payload plumbing -------------------------------------------
        inst = 32'h00510093;
        #1;
        expect_eq ("pc carried",     id_ex.pc,    32'h8000_0100);
        expect_eq ("rs1_v carried",  id_ex.rs1_v, 32'haaaa_aaaa);
        expect_eq ("rs2_v carried",  id_ex.rs2_v, 32'hbbbb_bbbb);
        expect_bit("valid carried",  id_ex.valid, 1'b1);

        if_id.valid = 1'b0;
        #1;
        expect_bit("invalid carried", id_ex.valid, 1'b0);

        // The halt encoding has to be recognised here, since it is the only
        // place the instruction word is still visible.
        if_id.valid = 1'b1;
        inst = 32'hf000_2013;
        #1;
        expect_bit("halt recognised", id_ex.is_halt, 1'b1);

        inst = 32'h00510093;
        #1;
        expect_bit("non-halt clear",  id_ex.is_halt, 1'b0);

        report("stage_id");
    end

endmodule
