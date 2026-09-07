// EX: operand selection with forwarding applied, the ALU and the mdu, branch
// resolution, and the redirect that squashes wrongly-fetched instructions.
//
// This stage applies forwarding but does not decide it -- the selects come from
// hazard.sv, so there is exactly one place to read if the forwarding is ever
// suspect. It does not decide stalling either, for the same reason: it reports
// md_req and md_ready and hazard.sv turns those into a stall.
//
// No longer purely combinational, and it is the only stage that is not. The
// divider inside the mdu is a 32-cycle machine, and by the rule cpu.sv sets out
// -- a register BETWEEN stages belongs there, a stage's OWN state belongs with
// the stage -- that machine is EX's, not the pipeline's. What that costs is
// worth knowing before debugging a divide: the instruction sits here for 34
// cycles while cpu.sv holds ID/EX and feeds bubbles into EX/MEM behind it.

module stage_ex
import rv32i_types::*;
import pipelined_types::*;
(
    input  logic        clk,
    input  logic        rst,

    input  id_ex_t      id_ex,

    // Forwarding: what to substitute, and the values to substitute from.
    input  fwd_sel_t    fwd_a,
    input  fwd_sel_t    fwd_b,
    input  logic [31:0] mem_fwd_value,
    input  logic [31:0] wb_fwd_value,

    output ex_mem_t     ex_mem,
    output logic        redirect,
    output logic [31:0] redirect_pc,

    // For hazard.sv: an M instruction is executing, and whether its result is
    // available this cycle. A multiply always answers yes.
    output logic        md_req,
    output logic        md_ready
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

    // RV32M, alongside the ALU rather than inside it: the multiply is a
    // different shape of logic and the divide has a different latency, and
    // folding either into alu.sv would put both into every instruction's path.
    //
    // The forwarded operands are handed over live. That is safe for the
    // multiply, which resolves in the same cycle, and NOT safe for the divide,
    // which is why the mdu captures them itself on its starting cycle -- the
    // bubbles this stall pushes into EX/MEM move the forwarding selects out
    // from under a value that has to stay still for 34 cycles.
    logic [31:0] md_result;

    assign md_req = id_ex.valid && id_ex.is_muldiv;

    mdu #(
        .SEQUENTIAL (1'b1)
    ) mdu_inst (
        .clk    (clk),
        .rst    (rst),
        .req    (md_req),
        .funct3 (id_ex.funct3),
        .a      (rs1_fwd),
        .b      (rs2_fwd),
        .result (md_result),
        .ready  (md_ready)
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
        // The mdu result takes the ALU's slot rather than travelling on a path
        // of its own, so MEM, WB and the forwarding network all stay unaware
        // that M exists. Safe because the two never compete: an M instruction
        // is not a load, a store, or a branch, so nothing downstream wants
        // alu_f to be an address or a target.
        ex_mem.alu_f      = id_ex.is_muldiv ? md_result : alu_f;
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
