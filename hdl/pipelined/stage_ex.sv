// EX: operand selection with forwarding applied, the ALU, branch resolution,
// and the redirect that squashes wrongly-fetched instructions.
//
// Combinational. This stage applies forwarding but does not decide it -- the
// selects come from hazard.sv, so there is exactly one place to read if the
// forwarding is ever suspect.

module stage_ex
import rv32i_types::*;
import pipelined_types::*;
(
    input  id_ex_t      id_ex,

    // Forwarding: what to substitute, and the values to substitute from.
    input  fwd_sel_t    fwd_a,
    input  fwd_sel_t    fwd_b,
    input  logic [31:0] mem_fwd_value,
    input  logic [31:0] wb_fwd_value,

    output ex_mem_t     ex_mem,
    output logic        redirect,
    output logic [31:0] redirect_pc
);

    logic [31:0] rs1_fwd, rs2_fwd;

    always_comb begin
        unique case (fwd_a)
            fwd_none: rs1_fwd = id_ex.rs1_v;
            fwd_mem:  rs1_fwd = mem_fwd_value;
            fwd_wb:   rs1_fwd = wb_fwd_value;
            default:  rs1_fwd = id_ex.rs1_v;
        endcase
        unique case (fwd_b)
            fwd_none: rs2_fwd = id_ex.rs2_v;
            fwd_mem:  rs2_fwd = mem_fwd_value;
            fwd_wb:   rs2_fwd = wb_fwd_value;
            default:  rs2_fwd = id_ex.rs2_v;
        endcase
    end

    logic [31:0] alu_a, alu_b, alu_f;

    always_comb begin
        unique case (id_ex.alu_a_sel)
            alu_a_rs1: alu_a = rs1_fwd;
            alu_a_pc:  alu_a = id_ex.pc;
        endcase
        unique case (id_ex.alu_b_sel)
            alu_b_rs2: alu_b = rs2_fwd;
            alu_b_imm: alu_b = id_ex.imm;
        endcase
    end

    alu alu_inst (
        .aluop(id_ex.aluop),
        .a    (alu_a),
        .b    (alu_b),
        .f    (alu_f)
    );

    // Compared directly rather than through the ALU, which is busy computing
    // the branch target in the same cycle.
    logic branch_taken;

    always_comb begin
        unique case (branch_f3_t'(id_ex.funct3))
            branch_f3_beq:  branch_taken = (rs1_fwd == rs2_fwd);
            branch_f3_bne:  branch_taken = (rs1_fwd != rs2_fwd);
            branch_f3_blt:  branch_taken = (signed'(rs1_fwd) <  signed'(rs2_fwd));
            branch_f3_bge:  branch_taken = (signed'(rs1_fwd) >= signed'(rs2_fwd));
            branch_f3_bltu: branch_taken = (rs1_fwd <  rs2_fwd);
            branch_f3_bgeu: branch_taken = (rs1_fwd >= rs2_fwd);
            default:        branch_taken = 1'b0;
        endcase
    end

    // Fetch runs straight ahead, so a taken branch or any jump costs the two
    // instructions already behind it. jalr additionally clears bit 0, which the
    // ISA mandates.
    assign redirect    = id_ex.valid && (id_ex.is_jal || id_ex.is_jalr
                                         || (id_ex.is_branch && branch_taken));
    assign redirect_pc = id_ex.is_jalr ? {alu_f[31:1], 1'b0} : alu_f;

    always_comb begin
        ex_mem.valid      = id_ex.valid;
        ex_mem.alu_f      = alu_f;
        ex_mem.pc4        = id_ex.pc + 32'd4;
        ex_mem.imm        = id_ex.imm;
        ex_mem.store_data = rs2_fwd;
        ex_mem.rd_s       = id_ex.rd_s;
        ex_mem.funct3     = id_ex.funct3;
        ex_mem.wb_sel     = id_ex.wb_sel;
        ex_mem.regf_we    = id_ex.regf_we;
        ex_mem.mem_read   = id_ex.mem_read;
        ex_mem.mem_write  = id_ex.mem_write;
        ex_mem.is_halt    = id_ex.is_halt;
    end

endmodule
