// Instruction decoder: turns a fetched word into the datapath's control
// signals. Purely combinational and stateless -- everything it needs is in the
// instruction itself.
//
// Two conventions worth knowing before reading the case statement:
//
//   * The ALU computes the branch/jump target as well as ordinary results. For
//     op_b_br and op_b_jal that means alu_a_pc + imm; for op_b_jalr, rs1 + imm.
//     Whether a branch is actually taken is decided by a separate comparator in
//     cpu.sv, which is why is_branch means "this is a branch", not "branch
//     taken".
//
//   * An unrecognised opcode falls through to the defaults below, which write
//     no register and touch no memory. It behaves as a NOP rather than
//     trapping; there is no exception support yet.

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
    logic        alt_op_bit;

    assign opcode = rv32i_opcode'(inst[6:0]);
    assign funct3 = inst[14:12];

    // funct7[5]. Declared as the single bit rather than the whole field because
    // it is the only bit of funct7 that RV32I gives meaning to -- carrying a
    // 7-bit signal with six dead bits just invites confusion.
    assign alt_op_bit = inst[30];

    // Shared by op_b_imm and op_b_reg. `alt_op` is inst[30] (funct7[5]), which
    // selects sub for add and sra for the shift-right pair. Callers are
    // responsible for passing it as 0 where it has no meaning -- for I-type,
    // inst[30] is part of the immediate, so only the shifts may consult it.
    function automatic alu_ops decode_alu_op(logic [2:0] f3, logic alt_op);
        unique case (arith_f3_t'(f3))
            arith_f3_add:  decode_alu_op = alt_op ? alu_op_sub : alu_op_add;
            arith_f3_sll:  decode_alu_op = alu_op_sll;
            arith_f3_slt:  decode_alu_op = alu_op_slt;
            arith_f3_sltu: decode_alu_op = alu_op_sltu;
            arith_f3_xor:  decode_alu_op = alu_op_xor;
            arith_f3_sr:   decode_alu_op = alt_op ? alu_op_sra : alu_op_srl;
            arith_f3_or:   decode_alu_op = alu_op_or;
            arith_f3_and:  decode_alu_op = alu_op_and;
        endcase
    endfunction

    always_comb begin
        // Defaults: compute nothing, commit nothing. Each arm below overrides
        // only what it actually needs, so a missing assignment reads as "this
        // instruction does not use that signal".
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

        unique case (opcode)

            // rd = imm[31:12] << 12. The ALU is not involved.
            op_b_lui: begin
                imm_sel = imm_u;
                wb_sel  = wb_imm;
                regf_we = 1'b1;
            end

            // rd = pc + (imm[31:12] << 12)
            op_b_auipc: begin
                imm_sel   = imm_u;
                alu_a_sel = alu_a_pc;
                alu_b_sel = alu_b_imm;
                aluop     = alu_op_add;
                wb_sel    = wb_alu;
                regf_we   = 1'b1;
            end

            // rd = pc + 4, pc = pc + imm. The ALU builds the target while the
            // writeback mux supplies the link value.
            op_b_jal: begin
                imm_sel   = imm_j;
                alu_a_sel = alu_a_pc;
                alu_b_sel = alu_b_imm;
                aluop     = alu_op_add;
                wb_sel    = wb_pc4;
                regf_we   = 1'b1;
                is_jal    = 1'b1;
            end

            // rd = pc + 4, pc = (rs1 + imm) with bit 0 cleared in cpu.sv.
            op_b_jalr: begin
                imm_sel   = imm_i;
                alu_a_sel = alu_a_rs1;
                alu_b_sel = alu_b_imm;
                aluop     = alu_op_add;
                wb_sel    = wb_pc4;
                regf_we   = 1'b1;
                is_jalr   = 1'b1;
            end

            // Target is pc + imm; the comparator in cpu.sv decides whether it
            // is used. Writes no register.
            op_b_br: begin
                imm_sel   = imm_b;
                alu_a_sel = alu_a_pc;
                alu_b_sel = alu_b_imm;
                aluop     = alu_op_add;
                is_branch = 1'b1;
            end

            // rd = mem[rs1 + imm], width and extension from funct3.
            op_b_load: begin
                imm_sel   = imm_i;
                alu_a_sel = alu_a_rs1;
                alu_b_sel = alu_b_imm;
                aluop     = alu_op_add;
                wb_sel    = wb_mem;
                mem_read  = 1'b1;
                regf_we   = 1'b1;
            end

            // mem[rs1 + imm] = rs2, width from funct3.
            op_b_store: begin
                imm_sel   = imm_s;
                alu_a_sel = alu_a_rs1;
                alu_b_sel = alu_b_imm;
                aluop     = alu_op_add;
                mem_write = 1'b1;
            end

            // rd = rs1 op imm. inst[30] is part of the immediate here, so only
            // the shift-right pair may read it -- ADDI has no SUBI.
            op_b_imm: begin
                imm_sel   = imm_i;
                alu_a_sel = alu_a_rs1;
                alu_b_sel = alu_b_imm;
                aluop     = decode_alu_op(funct3,
                                          alt_op_bit && (arith_f3_t'(funct3) == arith_f3_sr));
                wb_sel    = wb_alu;
                regf_we   = 1'b1;
            end

            // rd = rs1 op rs2, with inst[30] selecting sub and sra.
            op_b_reg: begin
                imm_sel   = imm_none;
                alu_a_sel = alu_a_rs1;
                alu_b_sel = alu_b_rs2;
                aluop     = decode_alu_op(funct3, alt_op_bit);
                wb_sel    = wb_alu;
                regf_we   = 1'b1;
            end

            default: ;  // unrecognised opcode: defaults above make it a NOP
        endcase
    end

endmodule
