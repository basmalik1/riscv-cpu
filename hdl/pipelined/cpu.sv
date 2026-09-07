// Five-stage pipelined RV32I core: IF, ID, EX, MEM, WB.
//
// This file is the wiring diagram. Each stage is a combinational module in its
// own file; the only logic here is state -- the program counter, the four
// pipeline registers, and the small amount of control deciding when they hold,
// advance or squash.
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

    if_id_t  if_id;
    id_ex_t  id_ex_n,  id_ex;
    ex_mem_t ex_mem_n, ex_mem;
    mem_wb_t mem_wb_n, mem_wb;

    logic        stall, redirect;
    logic [31:0] redirect_pc;

    // ==================================================================
    // IF
    // ==================================================================
    logic [31:0] pc;

    assign imem_addr = pc;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= RESET_PC;
        end else if (redirect) begin
            pc <= redirect_pc;
        end else if (!stall) begin
            pc <= pc + 32'd4;
        end
    end

    // ------------------------------ IF/ID -----------------------------
    // Carries no instruction: the memory's own output register is that. This
    // only has to remember which PC the in-flight fetch belongs to.
    always_ff @(posedge clk) begin
        if (rst || redirect) begin
            if_id.valid <= 1'b0;
            if_id.pc    <= '0;
        end else if (!stall) begin
            if_id.valid <= 1'b1;
            if_id.pc    <= pc;
        end
    end

    // A stall cannot be served by holding the PC. The memory read is
    // registered, so by the time ID knows it must stall the PC has already
    // advanced and the next fetch returns the FOLLOWING instruction while ID
    // still needs the current one -- which issues the stalled instruction
    // twice. Capture it on the first stalled cycle and replay from here.
    logic [31:0] held_inst;
    logic        held_valid;
    logic [31:0] id_inst;

    always_ff @(posedge clk) begin
        if (rst || redirect) begin
            held_valid <= 1'b0;
        end else if (stall && !held_valid) begin
            held_inst  <= imem_rdata;
            held_valid <= 1'b1;
        end else if (!stall) begin
            held_valid <= 1'b0;
        end
    end

    assign id_inst = held_valid ? held_inst : imem_rdata;

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
