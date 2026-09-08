// Single-issue out-of-order RV32IM core, R10K style.
//
// This file is the wiring diagram. Every piece of logic lives in a module that
// was built and tested before this one existed; what is here is the plumbing
// and the handful of decisions that only make sense once the pieces are joined.
//
// The shape, front to back:
//
//   fetch      program counter, straight ahead, redirected at commit
//   dispatch   rename: read the alias table, take a physical register, take a
//              reorder buffer slot, push into the issue queue. All or nothing
//   issue      the oldest instruction whose operands exist
//   execute    three independent paths sharing one result bus
//   commit     in order, oldest first, one per cycle
//
// Three things are worth knowing before reading it.
//
// THERE IS ONE RESULT BUS and it does three jobs at once: it writes the
// register file, wakes anything in the issue queue waiting on that tag, and
// tells the reorder buffer the instruction finished. Those are the same three
// wires going to three places, which is why NUM_WAKEUP is 1 here even though
// the issue queue can take more.
//
// RECOVERY IS ENTIRELY THE REORDER BUFFER'S. When a mispredicting instruction
// commits it walks the entries behind it, handing each one's physical register
// back through the same free-list port commit uses. Everything else just
// listens: fetch takes the redirect, the issue queue empties, execute drops
// what it was working on, and the alias table copies itself back from the
// retirement one. No structure needed a recovery mechanism of its own.
//
// THE TWO ALIAS TABLES ARE THE SAME MODULE. The speculative one is written at
// rename and is what in-flight instructions read; the retirement one is written
// at commit and is therefore architectural truth, which is what makes it the
// thing to restore from.

module cpu
import rv32i_types::*;
import ooo_types::*;
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
    output logic        commit,

    // Commit trace, identical to the other two cores so one testbench and one
    // comparator serve all three.
    output logic [31:0] commit_pc,
    output logic        commit_regf_we,
    output logic [4:0]  commit_rd_s,
    output logic [31:0] commit_rd_v,
    output logic        commit_mem_we,
    output logic [31:0] commit_mem_addr,
    output logic [31:0] commit_mem_wdata,
    output logic [1:0]  commit_mem_size
);

    localparam int unsigned IQ_DEPTH = 8;

    // ==================================================================
    // fetch
    // ==================================================================
    logic [31:0] if_inst, if_pc;
    logic        if_valid, if_stall;

    logic        rob_flush;
    logic [31:0] rob_flush_pc;

    fetch #(
        .RESET_PC   (RESET_PC)
    ) u_fetch (
        .clk        (clk),
        .rst        (rst),
        .stall      (if_stall),
        .flush      (rob_flush),
        .flush_pc   (rob_flush_pc),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .inst       (if_inst),
        .pc         (if_pc),
        .valid      (if_valid)
    );

    // ==================================================================
    // decode
    // ==================================================================
    alu_ops     aluop;
    alu_a_sel_t alu_a_sel;
    alu_b_sel_t alu_b_sel;
    imm_sel_t   imm_sel;
    wb_sel_t    wb_sel;
    logic       regf_we, mem_read, mem_write, is_branch, is_jal, is_jalr, is_muldiv;

    control u_control (
        .inst      (if_inst),
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
        .is_jalr   (is_jalr),
        .is_muldiv (is_muldiv)
    );

    // ==================================================================
    // rename
    // ==================================================================
    logic [PHYS_BITS-1:0] rat_rs1_tag, rat_rs2_tag, rat_rd_old_tag;
    logic                 prf_chk1_ready, prf_chk2_ready;
    logic [PHYS_BITS-1:0] fl_tag;
    logic                 fl_valid;
    logic                 rob_alloc_ready;
    logic [ROB_BITS-1:0]  rob_alloc_idx;
    logic                 iq_ready;

    logic                 dp_ready;
    logic [4:0]           dp_rs1_addr, dp_rs2_addr;
    logic [PHYS_BITS-1:0] dp_prf_rs1_tag, dp_prf_rs2_tag;
    logic                 dp_free_alloc;
    logic                 dp_rat_we;
    logic [4:0]           dp_rat_rd_addr;
    logic [PHYS_BITS-1:0] dp_rat_rd_tag;
    logic                 dp_prf_alloc;
    logic [PHYS_BITS-1:0] dp_prf_alloc_tag;
    logic                 dp_rob_alloc;
    logic [4:0]           dp_rob_rd_arch;
    logic [PHYS_BITS-1:0] dp_rob_rd_phys, dp_rob_rd_old_phys;
    logic                 dp_rob_writes_reg, dp_rob_is_halt;
    logic [31:0]          dp_rob_pc;
    logic                 dp_iq_dispatch;
    logic [PHYS_BITS-1:0] dp_iq_rs1, dp_iq_rs2;
    logic                 dp_iq_rs1_ready, dp_iq_rs2_ready;
    iq_payload_t          dp_iq_payload;

    dispatch u_dispatch (
        .valid          (if_valid),
        .inst           (if_inst),
        .pc             (if_pc),
        .aluop          (aluop),
        .alu_a_sel      (alu_a_sel),
        .alu_b_sel      (alu_b_sel),
        .imm_sel        (imm_sel),
        .wb_sel         (wb_sel),
        .regf_we        (regf_we),
        .mem_read       (mem_read),
        .mem_write      (mem_write),
        .is_branch      (is_branch),
        .is_jal         (is_jal),
        .is_jalr        (is_jalr),
        .is_muldiv      (is_muldiv),

        .rat_rs1_tag    (rat_rs1_tag),
        .rat_rs2_tag    (rat_rs2_tag),
        .rat_rd_old_tag (rat_rd_old_tag),
        .prf_rs1_ready  (prf_chk1_ready),
        .prf_rs2_ready  (prf_chk2_ready),
        .free_tag       (fl_tag),
        .free_valid     (fl_valid),
        .rob_ready      (rob_alloc_ready),
        .rob_idx        (rob_alloc_idx),
        .iq_ready       (iq_ready),

        /* verilator lint_off PINCONNECTEMPTY */
        // Nothing here reads it: every write port below is already gated by it
        // inside dispatch, so using it again would be asking the same question
        // twice. It stays an output because it is what tb_dispatch checks.
        .fire           (),
        /* verilator lint_on PINCONNECTEMPTY */
        .rs1_addr       (dp_rs1_addr),
        .rs2_addr       (dp_rs2_addr),
        .prf_rs1_tag    (dp_prf_rs1_tag),
        .prf_rs2_tag    (dp_prf_rs2_tag),
        .free_alloc     (dp_free_alloc),
        .rat_we         (dp_rat_we),
        .rat_rd_addr    (dp_rat_rd_addr),
        .rat_rd_tag     (dp_rat_rd_tag),
        .prf_alloc      (dp_prf_alloc),
        .prf_alloc_tag  (dp_prf_alloc_tag),
        .rob_alloc      (dp_rob_alloc),
        .rob_rd_arch    (dp_rob_rd_arch),
        .rob_rd_phys    (dp_rob_rd_phys),
        .rob_rd_old_phys(dp_rob_rd_old_phys),
        .rob_writes_reg (dp_rob_writes_reg),
        .rob_pc         (dp_rob_pc),
        .rob_is_halt    (dp_rob_is_halt),
        .iq_dispatch    (dp_iq_dispatch),
        .iq_rs1         (dp_iq_rs1),
        .iq_rs1_ready   (dp_iq_rs1_ready),
        .iq_rs2         (dp_iq_rs2),
        .iq_rs2_ready   (dp_iq_rs2_ready),
        .iq_payload     (dp_iq_payload),
        .ready          (dp_ready)
    );

    // Hold the instruction only when there IS one and dispatch could not take
    // it. With nothing valid there is nothing to lose by fetching on.
    assign if_stall = if_valid && !dp_ready;

    // ==================================================================
    // the rename structures
    // ==================================================================
    logic                 rob_free_valid;
    logic [PHYS_BITS-1:0] rob_free_phys;

    free_list #(
        .PHYS_REGS   (PHYS_REGS),
        .ARCH_REGS   (32)
    ) u_free_list (
        .clk         (clk),
        .rst         (rst),
        .alloc       (dp_free_alloc),
        .alloc_tag   (fl_tag),
        .alloc_valid (fl_valid),
        .free        (rob_free_valid),
        .free_tag    (rob_free_phys),
        /* verilator lint_off PINCONNECTEMPTY */
        // Full means every register is free, which is true at reset and after
        // the machine drains. Nothing here needs to know.
        .full        (),
        .count       ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    logic [31:0][PHYS_BITS-1:0] rrat_map;

    rat #(
        .PHYS_REGS   (PHYS_REGS),
        .ARCH_REGS   (32)
    ) u_rat (
        .clk         (clk),
        .rst         (rst),
        .rs1_addr    (dp_rs1_addr),
        .rs2_addr    (dp_rs2_addr),
        .rs1_tag     (rat_rs1_tag),
        .rs2_tag     (rat_rs2_tag),
        .we          (dp_rat_we),
        .rd_addr     (dp_rat_rd_addr),
        .rd_tag      (dp_rat_rd_tag),
        .rd_old_tag  (rat_rd_old_tag),
        /* verilator lint_off PINCONNECTEMPTY */
        // Only the retirement table's copy is read, by this one.
        .map_out     (),
        /* verilator lint_on PINCONNECTEMPTY */
        .restore     (rob_flush),
        .restore_map (rrat_map)
    );

    // The retirement table. Same module, written at commit instead of rename,
    // and therefore always the architectural mapping. Its read ports go
    // nowhere -- nothing asks it what a register maps to, only what the whole
    // table is.
    logic                 rob_commit;
    logic [4:0]           rob_commit_rd_arch;
    logic [PHYS_BITS-1:0] rob_commit_rd_phys;
    logic                 rob_commit_writes_reg;

    /* verilator lint_off PINCONNECTEMPTY */
    rat #(
        .PHYS_REGS   (PHYS_REGS),
        .ARCH_REGS   (32)
    ) u_rrat (
        .clk         (clk),
        .rst         (rst),
        .rs1_addr    (5'd0),
        .rs2_addr    (5'd0),
        .rs1_tag     (),
        .rs2_tag     (),
        .we          (rob_commit && rob_commit_writes_reg),
        .rd_addr     (rob_commit_rd_arch),
        .rd_tag      (rob_commit_rd_phys),
        .rd_old_tag  (),
        .map_out     (rrat_map),
        .restore     (1'b0),
        .restore_map ('0)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ==================================================================
    // the physical register file
    // ==================================================================
    logic [PHYS_BITS-1:0] ex_prf_rs1_tag, ex_prf_rs2_tag;
    logic [31:0]          prf_rs1_value, prf_rs2_value;
    logic                 wb_valid;
    logic [PHYS_BITS-1:0] wb_tag;
    logic [31:0]          wb_value;

    prf #(
        .PHYS_REGS    (PHYS_REGS)
    ) u_prf (
        .clk          (clk),
        .rst          (rst),
        .rs1_tag      (ex_prf_rs1_tag),
        .rs1_value    (prf_rs1_value),
        .rs2_tag      (ex_prf_rs2_tag),
        .rs2_value    (prf_rs2_value),
        .chk1_tag     (dp_prf_rs1_tag),
        .chk1_ready   (prf_chk1_ready),
        .chk2_tag     (dp_prf_rs2_tag),
        .chk2_ready   (prf_chk2_ready),
        .commit_tag   (rob_commit_rd_phys),
        .commit_value (commit_rd_v),
        .alloc        (dp_prf_alloc),
        .alloc_tag    (dp_prf_alloc_tag),
        .wb           (wb_valid),
        .wb_tag       (wb_tag),
        .wb_value     (wb_value)
    );

    // ==================================================================
    // the reorder buffer
    // ==================================================================
    logic [ROB_BITS-1:0] rob_head_idx;
    logic                ex_complete, ex_complete_mispredict;
    logic [ROB_BITS-1:0] ex_complete_idx;
    logic [31:0]         ex_complete_redirect_pc;

    rob #(
        .DEPTH                (ROB_DEPTH),
        .PHYS_REGS            (PHYS_REGS),
        .ARCH_REGS            (32)
    ) u_rob (
        .clk                  (clk),
        .rst                  (rst),
        .alloc                (dp_rob_alloc),
        .alloc_rd_arch        (dp_rob_rd_arch),
        .alloc_rd_phys        (dp_rob_rd_phys),
        .alloc_rd_old_phys    (dp_rob_rd_old_phys),
        .alloc_writes_reg     (dp_rob_writes_reg),
        .alloc_pc             (dp_rob_pc),
        .alloc_is_halt        (dp_rob_is_halt),
        .alloc_idx            (rob_alloc_idx),
        .head_idx             (rob_head_idx),
        .alloc_ready          (rob_alloc_ready),
        .complete             (ex_complete),
        .complete_idx         (ex_complete_idx),
        .complete_mispredict  (ex_complete_mispredict),
        .complete_redirect_pc (ex_complete_redirect_pc),
        .commit               (rob_commit),
        .commit_rd_arch       (rob_commit_rd_arch),
        .commit_rd_phys       (rob_commit_rd_phys),
        .commit_writes_reg    (rob_commit_writes_reg),
        .commit_pc            (commit_pc),
        .commit_halt          (halt),
        .flush                (rob_flush),
        .flush_pc             (rob_flush_pc),
        .free_valid           (rob_free_valid),
        .free_phys            (rob_free_phys),
        /* verilator lint_off PINCONNECTEMPTY */
        .empty                (),
        .full                 ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ==================================================================
    // the issue queue
    // ==================================================================
    logic        iq_issue_valid, iq_issue_accept;
    iq_payload_t iq_issue_payload;

    issue_queue #(
        .DEPTH              (IQ_DEPTH),
        .PHYS_REGS          (PHYS_REGS),
        .PAYLOAD_W          ($bits(iq_payload_t)),
        // One, because there is one result bus. The parameter exists for a
        // machine with more than one functional unit able to broadcast in the
        // same cycle; this one arbitrates instead.
        .NUM_WAKEUP         (1)
    ) u_iq (
        .clk                (clk),
        .rst                (rst),
        .dispatch           (dp_iq_dispatch),
        .dispatch_rs1       (dp_iq_rs1),
        .dispatch_rs1_ready (dp_iq_rs1_ready),
        .dispatch_rs2       (dp_iq_rs2),
        .dispatch_rs2_ready (dp_iq_rs2_ready),
        .dispatch_payload   (dp_iq_payload),
        .dispatch_ready     (iq_ready),
        .wake_valid         (wb_valid),
        .wake_tag           (wb_tag),
        .issue_valid        (iq_issue_valid),
        .issue_payload      (iq_issue_payload),
        .issue_accept       (iq_issue_accept),
        .flush              (rob_flush),
        /* verilator lint_off PINCONNECTEMPTY */
        .count              ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ==================================================================
    // execute
    // ==================================================================
    execute u_execute (
        .clk                  (clk),
        .rst                  (rst),
        .flush                (rob_flush),
        .issue_valid          (iq_issue_valid),
        .issue_payload        (iq_issue_payload),
        .issue_accept         (iq_issue_accept),
        .prf_rs1_tag          (ex_prf_rs1_tag),
        .prf_rs2_tag          (ex_prf_rs2_tag),
        .prf_rs1_value        (prf_rs1_value),
        .prf_rs2_value        (prf_rs2_value),
        .rob_head_idx         (rob_head_idx),
        .complete             (ex_complete),
        .complete_idx         (ex_complete_idx),
        .complete_mispredict  (ex_complete_mispredict),
        .complete_redirect_pc (ex_complete_redirect_pc),
        .wb_valid             (wb_valid),
        .wb_tag               (wb_tag),
        .wb_value             (wb_value),
        .dmem_addr            (dmem_addr),
        .dmem_wdata           (dmem_wdata),
        .dmem_rmask           (dmem_rmask),
        .dmem_wmask           (dmem_wmask),
        .dmem_rdata           (dmem_rdata)
    );

    // ==================================================================
    // commit
    // ==================================================================
    assign commit         = rob_commit;
    assign commit_regf_we = rob_commit && rob_commit_writes_reg;
    assign commit_rd_s    = rob_commit_rd_arch;

    // The store an instruction performed, reported when it commits rather than
    // when it executed, so the trace stays in program order.
    //
    // One register is enough for all of them, which is worth explaining. A
    // store only reaches memory once it is the OLDEST instruction in the
    // machine, and it stays the oldest until it commits -- so no second store
    // can execute in the window between this one executing and committing.
    // At most one is ever pending, and a per-entry field in the reorder buffer
    // would be sixty-six bits times thirty-two to hold what one register holds.
    logic                pend_valid;
    logic [ROB_BITS-1:0] pend_idx;
    logic [31:0]         pend_addr, pend_data;
    logic [1:0]          pend_size;

    // The EFFECTIVE address and the value as the ISA sees it, not the
    // word-aligned address and lane-shifted data the memory port carries.
    logic store_executing;
    assign store_executing = iq_issue_valid && iq_issue_accept
                             && iq_issue_payload.mem_write;

    always_ff @(posedge clk) begin
        if (rst || rob_flush) begin
            pend_valid <= 1'b0;
        end else if (store_executing) begin
            pend_valid <= 1'b1;
            pend_idx   <= iq_issue_payload.rob_idx;
            pend_addr  <= prf_rs1_value + iq_issue_payload.imm;
            pend_data  <= prf_rs2_value;
            pend_size  <= iq_issue_payload.funct3[1:0];
        end else if (rob_commit && pend_valid && (rob_head_idx == pend_idx)) begin
            pend_valid <= 1'b0;
        end
    end

    assign commit_mem_we    = rob_commit && pend_valid && (rob_head_idx == pend_idx);
    assign commit_mem_addr  = pend_addr;
    assign commit_mem_wdata = pend_data;
    assign commit_mem_size  = pend_size;

endmodule
