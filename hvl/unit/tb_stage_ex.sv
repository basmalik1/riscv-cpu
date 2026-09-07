// stage_ex: operand selection with forwarding applied, branch resolution, and
// the redirect. Forwarding is decided in hazard.sv and only applied here, so
// these tests drive the selects directly rather than inferring them.

module tb_stage_ex
import rv32i_types::*;
import pipelined_types::*;
;

    `include "tb_check.svh"

    id_ex_t      id_ex;
    fwd_sel_t    fwd_a, fwd_b;
    logic [31:0] mem_fwd_value, wb_fwd_value;
    ex_mem_t     ex_mem;
    logic        redirect;
    logic [31:0] redirect_pc;

    stage_ex dut (.*);

    task automatic clear();
        id_ex             = '0;
        id_ex.valid       = 1'b1;
        id_ex.aluop       = alu_op_add;
        id_ex.alu_a_sel   = alu_a_rs1;
        id_ex.alu_b_sel   = alu_b_rs2;
        id_ex.wb_sel      = wb_alu;
        id_ex.rs1_v       = 32'd10;
        id_ex.rs2_v       = 32'd20;
        fwd_a             = fwd_none;
        fwd_b             = fwd_none;
        // mem_fwd_value / wb_fwd_value are set once in initial and left alone,
        // so each test can tell which source a value came from.
    endtask

    initial begin
        mem_fwd_value = 32'h1111_1111;
        wb_fwd_value  = 32'h2222_2222;

        // ---- operand sources ---------------------------------------------
        clear(); #1;
        expect_eq("no forward uses ID values", ex_mem.alu_f, 32'd30);

        clear(); fwd_a = fwd_mem; #1;
        expect_eq("fwd_a from MEM", ex_mem.alu_f, 32'h1111_1111 + 32'd20);

        clear(); fwd_a = fwd_wb; #1;
        expect_eq("fwd_a from WB",  ex_mem.alu_f, 32'h2222_2222 + 32'd20);

        clear(); fwd_b = fwd_mem; #1;
        expect_eq("fwd_b from MEM", ex_mem.alu_f, 32'd10 + 32'h1111_1111);

        // An immediate operand ignores forwarding on that port entirely.
        clear();
        id_ex.alu_b_sel = alu_b_imm;
        id_ex.imm       = 32'd5;
        fwd_b           = fwd_mem;
        #1;
        expect_eq("imm ignores fwd_b", ex_mem.alu_f, 32'd15);

        // ---- pc as operand a, for auipc, jal and branch targets -----------
        clear();
        id_ex.alu_a_sel = alu_a_pc;
        id_ex.alu_b_sel = alu_b_imm;
        id_ex.pc        = 32'h8000_0100;
        id_ex.imm       = 32'd8;
        #1;
        expect_eq("pc + imm target", ex_mem.alu_f, 32'h8000_0108);

        // ---- branch conditions, both directions ---------------------------
        clear();
        id_ex.is_branch = 1'b1;
        id_ex.alu_a_sel = alu_a_pc;
        id_ex.alu_b_sel = alu_b_imm;
        id_ex.pc        = 32'h8000_0000;
        id_ex.imm       = 32'd16;

        id_ex.funct3 = 3'b000;                              // beq
        id_ex.rs1_v = 32'd5; id_ex.rs2_v = 32'd5; #1;
        expect_bit("beq equal taken", redirect, 1'b1);
        expect_eq ("beq target",      redirect_pc, 32'h8000_0010);
        id_ex.rs2_v = 32'd6; #1;
        expect_bit("beq unequal not taken", redirect, 1'b0);

        id_ex.funct3 = 3'b001; #1;                          // bne
        expect_bit("bne unequal taken", redirect, 1'b1);

        id_ex.funct3 = 3'b100;                              // blt, signed
        id_ex.rs1_v = -32'd1; id_ex.rs2_v = 32'd1; #1;
        expect_bit("blt -1 < 1 signed", redirect, 1'b1);

        id_ex.funct3 = 3'b110;                              // bltu, unsigned
        #1;
        expect_bit("bltu 0xffffffff not < 1", redirect, 1'b0);

        id_ex.funct3 = 3'b111;                              // bgeu
        #1;
        expect_bit("bgeu 0xffffffff >= 1", redirect, 1'b1);

        id_ex.funct3 = 3'b101;                              // bge, signed
        id_ex.rs1_v = 32'd1; id_ex.rs2_v = -32'd1; #1;
        expect_bit("bge 1 >= -1 signed", redirect, 1'b1);

        // A branch resolved from a forwarded value has to use the forwarded
        // value, not the stale one read in ID.
        clear();
        id_ex.is_branch = 1'b1;
        id_ex.funct3    = 3'b000;
        id_ex.rs1_v     = 32'd0;
        id_ex.rs2_v     = 32'h1111_1111;
        fwd_a           = fwd_mem;
        #1;
        expect_bit("branch uses forwarded operand", redirect, 1'b1);

        // ---- jumps --------------------------------------------------------
        clear();
        id_ex.is_jal    = 1'b1;
        id_ex.alu_a_sel = alu_a_pc;
        id_ex.alu_b_sel = alu_b_imm;
        id_ex.pc        = 32'h8000_0000;
        id_ex.imm       = 32'd12;
        #1;
        expect_bit("jal redirects", redirect, 1'b1);
        expect_eq ("jal target",    redirect_pc, 32'h8000_000c);
        expect_eq ("jal link value", ex_mem.pc4, 32'h8000_0004);

        // jalr must clear bit 0 of the computed target. An odd target is the
        // only way to see a missing mask.
        clear();
        id_ex.is_jalr   = 1'b1;
        id_ex.alu_b_sel = alu_b_imm;
        id_ex.rs1_v     = 32'h8000_0100;
        id_ex.imm       = 32'd1;
        #1;
        expect_eq("jalr clears bit 0", redirect_pc, 32'h8000_0100);

        // ---- a bubble must never redirect ---------------------------------
        clear();
        id_ex.valid  = 1'b0;
        id_ex.is_jal = 1'b1;
        #1;
        expect_bit("bubble does not redirect", redirect, 1'b0);

        // ---- store data takes the forwarded rs2 ---------------------------
        clear();
        id_ex.mem_write = 1'b1;
        fwd_b           = fwd_wb;
        #1;
        expect_eq("store data forwarded", ex_mem.store_data, 32'h2222_2222);

        report("stage_ex");
    end

endmodule
