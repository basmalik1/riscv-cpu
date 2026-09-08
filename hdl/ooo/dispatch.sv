// Dispatch: rename an instruction and hand it to all four structures at once.
//
// Combinational, and deliberately stateless. Everything it needs is a
// question it asks of somewhere else -- what does the alias table say rs1 maps
// to, is that register ready, is there a free tag, is there room in the reorder
// buffer, is there room in the issue queue -- and its entire job is to answer
// "can this instruction go" and, if so, to drive all five write ports in the
// same cycle.
//
// ALL OR NOTHING is the whole point. An instruction that takes a physical
// register but finds no reorder buffer slot has leaked that register with
// nothing left to free it, and the machine dies thousands of cycles later when
// the pool runs dry. So every consumer is enabled by one signal, `fire`, which
// is low unless every resource is available at once.
//
// x0 allocates nothing. An instruction whose destination is x0 has its result
// discarded by the ISA, so it takes no tag, writes no alias entry, and tells
// the reorder buffer it writes no register -- which is also what makes the
// guard inside rat.sv a belt rather than the only thing holding x0 up.

module dispatch
import rv32i_types::*;
import ooo_types::*;
(
    // ---------------- the instruction ----------------
    input  logic        valid,
    input  logic [31:0] inst,
    input  logic [31:0] pc,

    // Decoded elsewhere, by the same control.sv the other two cores use.
    input  alu_ops      aluop,
    input  alu_a_sel_t  alu_a_sel,
    input  alu_b_sel_t  alu_b_sel,
    input  imm_sel_t    imm_sel,
    input  wb_sel_t     wb_sel,
    input  logic        regf_we,
    input  logic        mem_read,
    input  logic        mem_write,
    input  logic        is_branch,
    input  logic        is_jal,
    input  logic        is_jalr,
    input  logic        is_muldiv,

    // ---------------- what the structures say ----------------
    input  logic [PHYS_BITS-1:0] rat_rs1_tag,
    input  logic [PHYS_BITS-1:0] rat_rs2_tag,
    input  logic [PHYS_BITS-1:0] rat_rd_old_tag,

    input  logic                 prf_rs1_ready,
    input  logic                 prf_rs2_ready,

    input  logic [PHYS_BITS-1:0] free_tag,
    input  logic                 free_valid,

    input  logic                 rob_ready,
    input  logic [ROB_BITS-1:0]  rob_idx,

    input  logic                 iq_ready,

    // ---------------- what dispatch drives ----------------
    output logic                 fire,

    // Register-file addresses, driven combinationally so the alias table and
    // the register file can be read in the same cycle the answer is used.
    output logic [4:0]           rs1_addr,
    output logic [4:0]           rs2_addr,
    output logic [PHYS_BITS-1:0] prf_rs1_tag,
    output logic [PHYS_BITS-1:0] prf_rs2_tag,

    output logic                 free_alloc,

    output logic                 rat_we,
    output logic [4:0]           rat_rd_addr,
    output logic [PHYS_BITS-1:0] rat_rd_tag,

    output logic                 prf_alloc,
    output logic [PHYS_BITS-1:0] prf_alloc_tag,

    output logic                 rob_alloc,
    output logic [4:0]           rob_rd_arch,
    output logic [PHYS_BITS-1:0] rob_rd_phys,
    output logic [PHYS_BITS-1:0] rob_rd_old_phys,
    output logic                 rob_writes_reg,
    output logic [31:0]          rob_pc,
    output logic                 rob_is_halt,

    output logic                 iq_dispatch,
    output logic [PHYS_BITS-1:0] iq_rs1,
    output logic                 iq_rs1_ready,
    output logic [PHYS_BITS-1:0] iq_rs2,
    output logic                 iq_rs2_ready,
    output iq_payload_t          iq_payload,

    // Low means the front end must hold this instruction and present it again.
    output logic                 ready
);

    logic [4:0] rd_addr;

    assign rs1_addr = inst[19:15];
    assign rs2_addr = inst[24:20];
    assign rd_addr  = inst[11:7];

    // A destination of x0 is discarded by the ISA, so it consumes no physical
    // register and leaves the alias table alone.
    logic allocates;
    assign allocates = regf_we && (rd_addr != 5'd0);

    // The reorder buffer and the issue queue are always needed; a physical
    // register only when there is a destination to rename.
    assign ready = rob_ready && iq_ready && (!allocates || free_valid);
    assign fire  = valid && ready;

    // Every write port, gated by the one signal. Nothing here may be enabled
    // on its own.
    assign free_alloc = fire && allocates;
    assign rat_we     = fire && allocates;
    assign prf_alloc  = fire && allocates;
    assign rob_alloc  = fire;
    assign iq_dispatch = fire;

    assign rat_rd_addr   = rd_addr;
    assign rat_rd_tag    = free_tag;
    assign prf_alloc_tag = free_tag;

    // The register file is read at the tags the alias table just produced,
    // which is what makes the ready bits below belong to this instruction.
    assign prf_rs1_tag = rat_rs1_tag;
    assign prf_rs2_tag = rat_rs2_tag;

    // ------------------------------------------------------------------
    // immediate assembly
    // ------------------------------------------------------------------
    // The same bit scrambling as the other two cores, and the ISA's rather
    // than ours: every format puts the sign bit at inst[31] and overlaps the
    // lower fields, which keeps this mux narrow.
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

    // ------------------------------------------------------------------
    // what each structure is told
    // ------------------------------------------------------------------
    assign rob_rd_arch     = rd_addr;
    assign rob_rd_phys     = free_tag;
    // The register this instruction DISPLACES, which is what commit releases.
    // Meaningless when nothing is allocated, and rob.sv ignores it then.
    assign rob_rd_old_phys = rat_rd_old_tag;
    assign rob_writes_reg  = allocates;
    assign rob_pc          = pc;
    assign rob_is_halt     = (inst == HALT_INST);

    assign iq_rs1       = rat_rs1_tag;
    assign iq_rs2       = rat_rs2_tag;
    assign iq_rs1_ready = prf_rs1_ready;
    assign iq_rs2_ready = prf_rs2_ready;

    always_comb begin
        iq_payload             = '0;
        iq_payload.rob_idx     = rob_idx;
        iq_payload.rd_phys     = free_tag;
        iq_payload.writes_reg  = allocates;
        iq_payload.rs1_phys    = rat_rs1_tag;
        iq_payload.rs2_phys    = rat_rs2_tag;
        iq_payload.pc          = pc;
        iq_payload.imm         = imm;
        iq_payload.aluop       = aluop;
        iq_payload.alu_a_sel   = alu_a_sel;
        iq_payload.alu_b_sel   = alu_b_sel;
        iq_payload.wb_sel      = wb_sel;
        iq_payload.funct3      = inst[14:12];
        iq_payload.is_branch   = is_branch;
        iq_payload.is_jal      = is_jal;
        iq_payload.is_jalr     = is_jalr;
        iq_payload.is_muldiv   = is_muldiv;
        iq_payload.mem_read    = mem_read;
        iq_payload.mem_write   = mem_write;
    end

endmodule
