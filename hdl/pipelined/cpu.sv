// Five-stage pipelined RV32I core: IF, ID, EX, MEM, WB.
//
// This file is the wiring diagram. Each stage lives in its own file, and the
// only logic here is the four pipeline registers plus the control deciding when
// they hold, advance or squash.
//
// Where state lives: a register BETWEEN stages belongs here. A stage's OWN
// state belongs with that stage. So the program counter and the held
// instruction are in stage_if -- fetch is inherently stateful, and a stage_if
// without them would be a bare mux -- while the register file is here, since it
// spans ID and WB and belongs to neither. Every other stage is combinational.
//
// The cost of that split, worth knowing before chasing a branch bug: the
// redirect path crosses three files. stage_ex decides a branch is taken,
// stage_if applies the new PC, and this file squashes the two instructions
// already fetched behind it.
//
// Assumes a SYNCHRONOUS-READ memory, which is the point rather than a
// concession: the fetch issued in IF lands at the start of ID and the load
// issued in MEM lands at the start of WB, so the pipeline registers absorb
// exactly the latency that forced the single-cycle core into a combinational
// read.
//
// Not handled, because RV32I without CSRs does not raise them: exceptions,
// interrupts, and memory ordering.

module cpu
import rv32i_types::*;
import pipelined_types::*;
#(
    parameter bit [31:0] RESET_PC = 32'h8000_0000
)(
    input  logic        clk,
    input  logic        rst,

    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_rmask,
    output logic [3:0]  dmem_wmask,
    input  logic [31:0] dmem_rdata,

    output logic        halt,
    output logic        commit
);

    if_id_t  if_id_n,  if_id;
    id_ex_t  id_ex_n,  id_ex;
    ex_mem_t ex_mem_n, ex_mem;
    mem_wb_t mem_wb_n, mem_wb;

    logic        stall, redirect;
    logic [31:0] redirect_pc;

    // ==================================================================
    // IF
    // ==================================================================
    logic [31:0] id_inst;

    stage_if #(
        .RESET_PC    (RESET_PC)
    ) u_if (
        .clk         (clk),
        .rst         (rst),
        .stall       (stall),
        .redirect    (redirect),
        .redirect_pc (redirect_pc),
        .imem_addr   (imem_addr),
        .imem_rdata  (imem_rdata),
        .inst        (id_inst),
        .if_id_n     (if_id_n)
    );

    // ------------------------------ IF/ID -----------------------------
    // Carries no instruction: the memory's own output register is that, so
    // this only remembers which PC the in-flight fetch belongs to.
    always_ff @(posedge clk) begin
        if (rst || redirect) begin
            if_id <= '0;
        end else if (!stall) begin
            if_id <= if_id_n;
        end
    end

    // ==================================================================
    // ID
    // ==================================================================
    logic [4:0]  id_rs1_s, id_rs2_s;
    rv32i_opcode id_opcode;
    logic [31:0] id_rs1_v, id_rs2_v;

    stage_id u_id (
        .if_id  (if_id),
        .inst   (id_inst),
        .rs1_v  (id_rs1_v),
        .rs2_v  (id_rs2_v),
        .rs1_s  (id_rs1_s),
        .rs2_s  (id_rs2_s),
        .opcode (id_opcode),
        .id_ex  (id_ex_n)
    );

    // Spans ID and WB, so it sits here rather than inside either stage.
    // WRITE_FIRST covers WB writing the register ID is reading this cycle.
    logic [31:0] wb_value;
    logic [4:0]  wb_rd_s;
    logic        wb_regf_we;

    regfile #(
        .WRITE_FIRST (1'b1)
    ) regfile_inst (
        .clk    (clk),
        .rst    (rst),
        .regf_we(wb_regf_we),
        .rd_v   (wb_value),
        .rs1_s  (id_rs1_s),
        .rs2_s  (id_rs2_s),
        .rd_s   (wb_rd_s),
        .rs1_v  (id_rs1_v),
        .rs2_v  (id_rs2_v)
    );

    // ------------------------------ ID/EX -----------------------------
    // A stall inserts a bubble rather than holding, so the instruction stuck in
    // ID is re-decoded next cycle from the held instruction above.
    always_ff @(posedge clk) begin
        if (rst || redirect || stall) begin
            id_ex <= '0;
        end else begin
            id_ex <= id_ex_n;
        end
    end

    // ==================================================================
    // EX
    // ==================================================================
    fwd_sel_t    fwd_a, fwd_b;
    logic [31:0] mem_fwd_value;

    stage_ex u_ex (
        .id_ex         (id_ex),
        .fwd_a         (fwd_a),
        .fwd_b         (fwd_b),
        .mem_fwd_value (mem_fwd_value),
        .wb_fwd_value  (wb_value),
        .ex_mem        (ex_mem_n),
        .redirect      (redirect),
        .redirect_pc   (redirect_pc)
    );

    // ----------------------------- EX/MEM -----------------------------
    // Nothing past EX ever stalls; bubbles simply flow through.
    always_ff @(posedge clk) begin
        if (rst) begin
            ex_mem <= '0;
        end else begin
            ex_mem <= ex_mem_n;
        end
    end

    // ==================================================================
    // MEM
    // ==================================================================
    stage_mem u_mem (
        .ex_mem     (ex_mem),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_rmask (dmem_rmask),
        .dmem_wmask (dmem_wmask),
        .fwd_value  (mem_fwd_value),
        .mem_wb     (mem_wb_n)
    );

    // ----------------------------- MEM/WB -----------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_wb <= '0;
        end else begin
            mem_wb <= mem_wb_n;
        end
    end

    // ==================================================================
    // WB
    // ==================================================================
    stage_wb u_wb (
        .mem_wb     (mem_wb),
        .dmem_rdata (dmem_rdata),
        .wb_value   (wb_value),
        .rd_s       (wb_rd_s),
        .regf_we    (wb_regf_we),
        .halt       (halt),
        .commit     (commit)
    );

    // ==================================================================
    // hazards
    // ==================================================================
    hazard u_hazard (
        .id_valid  (if_id.valid),
        .id_opcode (id_opcode),
        .id_rs1_s  (id_rs1_s),
        .id_rs2_s  (id_rs2_s),
        .id_ex     (id_ex),
        .ex_mem    (ex_mem),
        .mem_wb    (mem_wb),
        .fwd_a     (fwd_a),
        .fwd_b     (fwd_b),
        .stall     (stall)
    );

endmodule
