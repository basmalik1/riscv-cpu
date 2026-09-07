// ID: decode, immediate assembly, and packaging the ID/EX payload.
//
// Combinational. The register file lives in cpu.sv because it spans ID and WB,
// so this stage receives the read values rather than owning the array.

module stage_id
import rv32i_types::*;
import pipelined_types::*;
(
    input  if_id_t      if_id,
    input  logic [31:0] inst,

    // Read back from the register file, which cpu.sv addresses with the
    // rs1_s / rs2_s this stage exposes below.
    input  logic [31:0] rs1_v,
    input  logic [31:0] rs2_v,

    output logic [4:0]  rs1_s,
    output logic [4:0]  rs2_s,
    output rv32i_opcode opcode,

    output id_ex_t      id_ex
);

    assign rs1_s  = inst[19:15];
    assign rs2_s  = inst[24:20];
    assign opcode = rv32i_opcode'(inst[6:0]);

    alu_ops     aluop;
    alu_a_sel_t alu_a_sel;
    alu_b_sel_t alu_b_sel;
    imm_sel_t   imm_sel;
    wb_sel_t    wb_sel;
    logic       regf_we, mem_read, mem_write, is_branch, is_jal, is_jalr;

    control control_unit (
        .inst      (inst),
        .aluop     (aluop),
        .alu_a_sel (alu_a_sel),
        .alu_b_sel (alu_b_sel),
        .imm_sel   (imm_sel),
        .wb_sel    (wb_sel),
        .regf_we   (regf_we),
        .mem_read  (mem_read),
        .mem_write (mem_write),
        .is_branch (is_branch),
        .is_jal    (is_jal),
        .is_jalr   (is_jalr)
    );

    // The bit scrambling is the ISA's, not ours: the formats put the sign bit
    // at inst[31] in every case and overlap the lower fields, which is what
    // keeps this mux narrow.
    logic [31:0] imm;

    always_comb begin
        unique case (imm_sel)
            imm_i:   imm = {{20{inst[31]}}, inst[31:20]};
            imm_s:   imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};
            imm_b:   imm = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
            imm_u:   imm = {inst[31:12], 12'b0};
            imm_j:   imm = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
            default: imm = '0;
        endcase
    end

    always_comb begin
        id_ex.valid     = if_id.valid;
        id_ex.pc        = if_id.pc;
        id_ex.imm       = imm;
        id_ex.rs1_v     = rs1_v;
        id_ex.rs2_v     = rs2_v;
        id_ex.rs1_s     = rs1_s;
        id_ex.rs2_s     = rs2_s;
        id_ex.rd_s      = inst[11:7];
        id_ex.funct3    = inst[14:12];
        id_ex.aluop     = aluop;
        id_ex.alu_a_sel = alu_a_sel;
        id_ex.alu_b_sel = alu_b_sel;
        id_ex.wb_sel    = wb_sel;
        id_ex.regf_we   = regf_we;
        id_ex.mem_read  = mem_read;
        id_ex.mem_write = mem_write;
        id_ex.is_branch = is_branch;
        id_ex.is_jal    = is_jal;
        id_ex.is_jalr   = is_jalr;
        id_ex.is_halt   = (inst == HALT_INST);
    end

endmodule
