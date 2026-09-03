module control
import rv32i_types::*;
(
    input  logic [31:0] inst,

    output alu_ops      aluop,
    output alu_a_sel_t  alu_a_sel,
    output alu_b_sel_t  alu_b_sel,
    output imm_sel_t    imm_sel,
    output wb_sel_t     wb_sel,

    output logic        regf_we,
    output logic        mem_read,
    output logic        mem_write,
    output logic        is_branch,
    output logic        is_jal,
    output logic        is_jalr
);

    rv32i_opcode opcode;
    logic [2:0]  funct3;
    logic [6:0]  funct7;

    assign opcode = rv32i_opcode'(inst[6:0]);
    assign funct3 = inst[14:12];
    assign funct7 = inst[31:25];

    // TODO: decode `opcode` into the control signals below.
    //   op_b_lui   -> wb_imm, imm_u
    //   op_b_auipc -> alu_a_pc + alu_b_imm, imm_u
    //   op_b_jal   -> is_jal, wb_pc4, imm_j
    //   op_b_jalr  -> is_jalr, wb_pc4, imm_i
    //   op_b_br    -> is_branch, imm_b   (branch_unit decides taken/not-taken)
    //   op_b_load  -> mem_read, wb_mem, imm_i
    //   op_b_store -> mem_write, imm_s
    //   op_b_imm   -> aluop from funct3 (funct7[5] selects sra for arith_f3_sr)
    //   op_b_reg   -> aluop from funct3 and funct7[5]
    always_comb begin
        aluop     = alu_op_add;
        alu_a_sel = alu_a_rs1;
        alu_b_sel = alu_b_imm;
        imm_sel   = imm_none;
        wb_sel    = wb_alu;

        regf_we   = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        is_branch = 1'b0;
        is_jal    = 1'b0;
        is_jalr   = 1'b0;
    end

endmodule
