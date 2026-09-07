// alu: every operation, with the cases that actually go wrong.

module tb_alu
import rv32i_types::*;
;

    `include "tb_check.svh"

    alu_ops      aluop;
    logic [31:0] a, b, f;

    alu dut (.aluop(aluop), .a(a), .b(b), .f(f));

    task automatic run(string what, alu_ops op, logic [31:0] x, logic [31:0] y,
                       logic [31:0] want);
        aluop = op;
        a = x;
        b = y;
        #1;
        expect_eq(what, f, want);
    endtask

    initial begin
        run("add",              alu_op_add,  32'd100, 32'd42,  32'd142);
        run("add wraps",        alu_op_add,  32'hffff_ffff, 32'd1, 32'd0);
        run("sub",              alu_op_sub,  32'd100, 32'd42,  32'd58);
        run("sub negative",     alu_op_sub,  32'd42,  32'd100, -32'd58);

        run("and",              alu_op_and,  32'hff00, 32'h0ff0, 32'h0f00);
        run("or",               alu_op_or,   32'hff00, 32'h0ff0, 32'hfff0);
        run("xor",              alu_op_xor,  32'hff00, 32'h0ff0, 32'hf0f0);

        run("sll",              alu_op_sll,  32'd1, 32'd4,  32'd16);
        run("sll to msb",       alu_op_sll,  32'd1, 32'd31, 32'h8000_0000);
        // Only rs2[4:0] counts. A shift of 33 must behave as a shift of 1.
        run("sll masks shamt",  alu_op_sll,  32'd1, 32'd33, 32'd2);

        run("srl",              alu_op_srl,  32'h8000_0000, 32'd4, 32'h0800_0000);
        run("srl masks shamt",  alu_op_srl,  32'h8000_0000, 32'd33, 32'h4000_0000);

        // sra floods the sign bit; srl does not. Getting these two confused is
        // the classic shift bug.
        run("sra floods sign",  alu_op_sra,  32'h8000_0000, 32'd4, 32'hf800_0000);
        run("sra of positive",  alu_op_sra,  32'h4000_0000, 32'd4, 32'h0400_0000);
        run("sra by 31",        alu_op_sra,  32'h8000_0000, 32'd31, 32'hffff_ffff);

        // slt is signed, sltu is not: -1 is less than 1, but 0xffffffff is not.
        run("slt signed true",  alu_op_slt,  -32'd1, 32'd1, 32'd1);
        run("slt signed false", alu_op_slt,  32'd1, -32'd1, 32'd0);
        run("slt equal",        alu_op_slt,  32'd7, 32'd7,  32'd0);
        run("sltu unsigned",    alu_op_sltu, 32'hffff_ffff, 32'd1, 32'd0);
        run("sltu true",        alu_op_sltu, 32'd1, 32'hffff_ffff, 32'd1);
        // slt had an equal case and sltu did not, which let a mutation to
        // `<=` through every layer of the suite. Equal operands are the only
        // input that separates the two comparisons.
        run("sltu equal",       alu_op_sltu, 32'd7, 32'd7,  32'd0);
        run("sltu equal zero",  alu_op_sltu, 32'd0, 32'd0,  32'd0);
        run("sltu equal max",   alu_op_sltu, 32'hffff_ffff, 32'hffff_ffff, 32'd0);

        report("alu");
    end

endmodule
