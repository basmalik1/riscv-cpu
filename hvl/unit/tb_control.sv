// control: one instruction per opcode class, checking the signals that decide
// what the datapath does with it.

module tb_control
import rv32i_types::*;
;

    `include "tb_check.svh"

    logic [31:0] inst;
    alu_ops      aluop;
    alu_a_sel_t  alu_a_sel;
    alu_b_sel_t  alu_b_sel;
    imm_sel_t    imm_sel;
    wb_sel_t     wb_sel;
    logic        regf_we, mem_read, mem_write, is_branch, is_jal, is_jalr;
    logic        is_muldiv;

    control dut (.*);

    initial begin
        // addi x1, x2, 5
        inst = 32'h00510093; #1;
        expect_bit("addi writes rd",     regf_we, 1'b1);
        expect_bit("addi is not a load", mem_read, 1'b0);
        expect_eq ("addi imm_i",         {29'd0, imm_sel},   {29'd0, imm_i});
        expect_eq ("addi alu add",       {28'd0, aluop},     {28'd0, alu_op_add});
        expect_eq ("addi b from imm",    {31'd0, alu_b_sel}, {31'd0, alu_b_imm});

        // srai x1, x2, 1 -- inst[30] set, and here it DOES mean arithmetic.
        inst = 32'h40115093; #1;
        expect_eq ("srai selects sra",   {28'd0, aluop}, {28'd0, alu_op_sra});

        // addi x1, x2, 0x400 -- inst[30] set as part of the IMMEDIATE, not a
        // funct7. If the decoder reads it here, addi silently becomes sub.
        inst = 32'h40010093; #1;
        expect_eq ("addi ignores inst30", {28'd0, aluop}, {28'd0, alu_op_add});

        // sub x1, x2, x3 -- inst[30] set, and here it does mean subtract.
        inst = 32'h403100b3; #1;
        expect_eq ("sub selects sub",    {28'd0, aluop},     {28'd0, alu_op_sub});
        expect_eq ("sub b from rs2",     {31'd0, alu_b_sel}, {31'd0, alu_b_rs2});

        // add x1, x2, x3
        inst = 32'h003100b3; #1;
        expect_eq ("add selects add",    {28'd0, aluop}, {28'd0, alu_op_add});

        // lw x1, 0(x2)
        inst = 32'h00012083; #1;
        expect_bit("lw reads memory",    mem_read, 1'b1);
        expect_bit("lw writes rd",       regf_we,  1'b1);
        expect_eq ("lw wb from memory",  {30'd0, wb_sel}, {30'd0, wb_mem});

        // sw x3, 0(x2)
        inst = 32'h00312023; #1;
        expect_bit("sw writes memory",   mem_write, 1'b1);
        expect_bit("sw writes no rd",    regf_we,   1'b0);
        expect_eq ("sw imm_s",           {29'd0, imm_sel}, {29'd0, imm_s});

        // beq x1, x2, +8
        inst = 32'h00208463; #1;
        expect_bit("beq is a branch",    is_branch, 1'b1);
        expect_bit("beq writes no rd",   regf_we,   1'b0);
        expect_eq ("beq target from pc", {31'd0, alu_a_sel}, {31'd0, alu_a_pc});
        expect_eq ("beq imm_b",          {29'd0, imm_sel},   {29'd0, imm_b});

        // jal x1, +8
        inst = 32'h008000ef; #1;
        expect_bit("jal is a jump",      is_jal,  1'b1);
        expect_bit("jal writes rd",      regf_we, 1'b1);
        expect_eq ("jal links pc+4",     {30'd0, wb_sel}, {30'd0, wb_pc4});

        // jalr x1, x2, 0
        inst = 32'h000100e7; #1;
        expect_bit("jalr is a jump",     is_jalr, 1'b1);
        expect_eq ("jalr from rs1",      {31'd0, alu_a_sel}, {31'd0, alu_a_rs1});
        expect_eq ("jalr links pc+4",    {30'd0, wb_sel},    {30'd0, wb_pc4});

        // lui x1, 0x12345
        inst = 32'h123450b7; #1;
        expect_eq ("lui wb from imm",    {30'd0, wb_sel},  {30'd0, wb_imm});
        expect_eq ("lui imm_u",          {29'd0, imm_sel}, {29'd0, imm_u});

        // auipc x1, 0x1
        inst = 32'h00001097; #1;
        expect_eq ("auipc a from pc",    {31'd0, alu_a_sel}, {31'd0, alu_a_pc});
        expect_eq ("auipc wb from alu",  {30'd0, wb_sel},    {30'd0, wb_alu});

        // ---- RV32M shares op_b_reg and is told apart by funct7 ------------
        // mul x1, x2, x3 -- the same encoding as add with funct7 = 0000001.
        inst = 32'h023100b3; #1;
        expect_bit("mul is an M instruction", is_muldiv, 1'b1);
        expect_bit("mul writes rd",           regf_we,   1'b1);
        expect_eq ("mul wb from alu slot",    {30'd0, wb_sel}, {30'd0, wb_alu});
        expect_eq ("mul b from rs2",          {31'd0, alu_b_sel}, {31'd0, alu_b_rs2});
        expect_bit("mul touches no memory",   mem_read,  1'b0);
        expect_bit("mul is not a branch",     is_branch, 1'b0);

        // div x1, x2, x3 -- funct3 100, the other family.
        inst = 32'h023140b3; #1;
        expect_bit("div is an M instruction", is_muldiv, 1'b1);
        expect_bit("div writes rd",           regf_we,   1'b1);

        // remu x1, x2, x3 -- funct3 111, which as an ALU op would be `and`.
        // The aluop is forced to add for every M instruction so that a stray
        // ALU result is at least defined rather than a plausible wrong answer.
        inst = 32'h023170b3; #1;
        expect_bit("remu is an M instruction", is_muldiv, 1'b1);
        expect_eq ("M forces aluop to add",    {28'd0, aluop}, {28'd0, alu_op_add});

        // add and sub must not be caught by the M check.
        inst = 32'h003100b3; #1;
        expect_bit("add is not an M instruction", is_muldiv, 1'b0);
        inst = 32'h403100b3; #1;
        expect_bit("sub is not an M instruction", is_muldiv, 1'b0);

        // A reserved funct7 must not decode as M either. This is the check
        // that fails if the decoder tests one bit of funct7 instead of all
        // seven -- funct7 0000010 shares no bit pattern with 0000001 except
        // being small, and every reserved encoding would become a multiply.
        inst = 32'h043100b3; #1;
        expect_bit("reserved funct7 is not M", is_muldiv, 1'b0);

        // addi with the same funct3 as mul is an I-type: funct7 does not exist
        // there, those bits are the immediate.
        inst = 32'h02310093; #1;
        expect_bit("addi is never M", is_muldiv, 1'b0);

        // An unrecognised opcode must commit nothing rather than do something
        // arbitrary. There are no exceptions in this core, so it becomes a nop.
        inst = 32'hffff_ffff; #1;
        expect_bit("illegal writes no rd",  regf_we,   1'b0);
        expect_bit("illegal reads no mem",  mem_read,  1'b0);
        expect_bit("illegal writes no mem", mem_write, 1'b0);
        expect_bit("illegal is not M",      is_muldiv, 1'b0);

        report("control");
    end

endmodule
