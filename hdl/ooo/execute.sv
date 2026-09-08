// Execute: read the operands, do the work, broadcast the result.
//
// Three independent paths, and that independence is the entire point of the
// iteration. If one instruction at a time occupied execute, a 34-cycle divide
// would stop the machine exactly as it stops the pipelined core, and the
// out-of-order core would have bought nothing. So the divider runs on its own
// while arithmetic keeps issuing past it:
//
//   fast   ALU, branches, jumps and multiplies. Resolve in the cycle they
//          issue, so they hold no state at all.
//   mdu    Divides. Occupies the multiply/divide unit for 34 cycles.
//   mem    Loads and stores. One cycle to present the address, one to take
//          the data back, because the memory read is synchronous.
//
// ONE COMMON DATA BUS, with the slow paths given priority. Two paths finishing
// together is ordinary, and rather than a second bus -- which costs a
// comparator per port per issue-queue entry and a second write port on the
// register file -- the fast path simply does not issue on a cycle a slow one
// is broadcasting. Priority runs mem, then mdu, then fast, so a stream of
// arithmetic can never starve a result that has already waited 34 cycles. The
// fast path is the one that can be told to wait, because it has not started
// yet: refusing it costs a cycle, refusing a finished divide would lose it.
//
// MEMORY IS NON-SPECULATIVE. There is no load/store queue yet, so a memory
// operation may only touch memory once it is the oldest instruction in the
// machine. That single rule gives both of the things a load/store queue would
// otherwise have to provide: memory operations stay in program order with
// respect to each other, and none of them happens on a path that turns out to
// be wrong. The cost is that a memory operation sitting at the head of the
// issue queue blocks younger work behind it -- a throughput loss, not a
// deadlock, since whatever it is waiting for is older and therefore ahead of
// it everywhere.

module execute
import rv32i_types::*;
import ooo_types::*;
(
    input  logic clk,
    input  logic rst,
    input  logic flush,

    // ---------------- from the issue queue ----------------
    input  logic         issue_valid,
    input  iq_payload_t  issue_payload,
    output logic         issue_accept,

    // ---------------- register file ----------------
    output logic [PHYS_BITS-1:0] prf_rs1_tag,
    output logic [PHYS_BITS-1:0] prf_rs2_tag,
    input  logic [31:0]          prf_rs1_value,
    input  logic [31:0]          prf_rs2_value,

    // ---------------- reorder buffer ----------------
    input  logic [ROB_BITS-1:0]  rob_head_idx,
    output logic                 complete,
    output logic [ROB_BITS-1:0]  complete_idx,
    output logic                 complete_mispredict,
    output logic [31:0]          complete_redirect_pc,

    // ---------------- the common data bus ----------------
    output logic                 wb_valid,
    output logic [PHYS_BITS-1:0] wb_tag,
    output logic [31:0]          wb_value,

    // ---------------- data memory ----------------
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_rmask,
    output logic [3:0]  dmem_wmask,
    input  logic [31:0] dmem_rdata
);

    // What a long-latency operation has to remember about itself. Only these
    // four fields survive the issue cycle: which reorder buffer entry to
    // complete, where the result goes and whether there is one, and the funct3
    // that decides how the answer is assembled. Holding the whole payload
    // instead would be ninety-odd bits of state to carry four that are read.
    typedef struct packed {
        logic [ROB_BITS-1:0]  rob_idx;
        logic [PHYS_BITS-1:0] rd_phys;
        logic                 writes_reg;
        logic [2:0]           funct3;
    } inflight_t;

    // ------------------------------------------------------------------
    // what kind of instruction is being offered
    // ------------------------------------------------------------------
    logic is_mem, is_div, is_mul;

    assign is_mem = issue_payload.mem_read || issue_payload.mem_write;
    // funct3[2] splits the M extension: multiplies resolve combinationally and
    // belong on the fast path, divides do not.
    assign is_div = issue_payload.is_muldiv &&  issue_payload.funct3[2];
    assign is_mul = issue_payload.is_muldiv && !issue_payload.funct3[2];

    assign prf_rs1_tag = issue_payload.rs1_phys;
    assign prf_rs2_tag = issue_payload.rs2_phys;

    // ------------------------------------------------------------------
    // the fast path
    // ------------------------------------------------------------------
    logic [31:0] alu_a, alu_b, alu_f;

    always_comb begin
        unique case (issue_payload.alu_a_sel)
            alu_a_rs1: alu_a = prf_rs1_value;
            alu_a_pc:  alu_a = issue_payload.pc;
        endcase
        unique case (issue_payload.alu_b_sel)
            alu_b_rs2: alu_b = prf_rs2_value;
            alu_b_imm: alu_b = issue_payload.imm;
        endcase
    end

    alu alu_inst (
        .aluop (issue_payload.aluop),
        .a     (alu_a),
        .b     (alu_b),
        .f     (alu_f)
    );

    // Compared directly rather than through the ALU, which is busy computing
    // the branch target in the same cycle.
    logic branch_taken;

    always_comb begin
        unique case (branch_f3_t'(issue_payload.funct3))
            branch_f3_beq:  branch_taken = (prf_rs1_value == prf_rs2_value);
            branch_f3_bne:  branch_taken = (prf_rs1_value != prf_rs2_value);
            branch_f3_blt:  branch_taken = (signed'(prf_rs1_value) <  signed'(prf_rs2_value));
            branch_f3_bge:  branch_taken = (signed'(prf_rs1_value) >= signed'(prf_rs2_value));
            branch_f3_bltu: branch_taken = (prf_rs1_value <  prf_rs2_value);
            branch_f3_bgeu: branch_taken = (prf_rs1_value >= prf_rs2_value);
            default:        branch_taken = 1'b0;
        endcase
    end

    // There is no branch predictor, so fetch runs straight ahead and every
    // taken branch or jump is a misprediction by definition.
    logic        fast_mispredict;
    logic [31:0] fast_redirect;

    assign fast_mispredict = issue_payload.is_jal || issue_payload.is_jalr
                             || (issue_payload.is_branch && branch_taken);
    // jalr additionally clears bit 0, which the ISA mandates.
    assign fast_redirect   = issue_payload.is_jalr ? {alu_f[31:1], 1'b0} : alu_f;

    // ------------------------------------------------------------------
    // the multiply/divide unit
    // ------------------------------------------------------------------
    // Held rather than read live. The unit captures its operands itself, but
    // its funct3 chooses the result at the END of the operation, so if that
    // moved when the next instruction issued the answer would be assembled for
    // the wrong instruction.
    logic                 mdu_busy;
    inflight_t            mdu_payload;
    logic [31:0]          mdu_a, mdu_b;
    logic [31:0]          mdu_result;
    logic                 mdu_ready;

    mdu #(
        .SEQUENTIAL (1'b1)
    ) mdu_inst (
        .clk    (clk),
        .rst    (rst),
        .req    (mdu_busy),
        .funct3 (mdu_busy ? mdu_payload.funct3 : issue_payload.funct3),
        .a      (mdu_busy ? mdu_a : prf_rs1_value),
        .b      (mdu_busy ? mdu_b : prf_rs2_value),
        .result (mdu_result),
        .ready  (mdu_ready)
    );

    // A multiply resolves combinationally, so it never sets mdu_busy and rides
    // the fast path. Reading the unit's output while it is idle is exactly what
    // gives the product.
    logic [31:0] mul_result;
    assign mul_result = mdu_result;

    logic mdu_done;
    assign mdu_done = mdu_busy && mdu_ready;

    // ------------------------------------------------------------------
    // the memory path
    // ------------------------------------------------------------------
    logic        mem_busy;
    inflight_t   mem_payload;
    logic [1:0]  mem_byte_off;

    logic [3:0] size_mask;

    // funct3[1:0] encodes the width identically for loads and stores.
    always_comb begin
        unique case (issue_payload.funct3[1:0])
            2'b00:   size_mask = 4'b0001;
            2'b01:   size_mask = 4'b0011;
            2'b10:   size_mask = 4'b1111;
            default: size_mask = 4'b0000;
        endcase
    end

    // Presented in the cycle the memory operation is accepted. alu_f is its
    // effective address, since control.sv gives a load or store the same
    // rs1 + imm the ALU computes for anything else.
    logic mem_start;

    assign dmem_addr  = {alu_f[31:2], 2'b00};
    assign dmem_rmask = (mem_start && issue_payload.mem_read)
                        ? (size_mask << alu_f[1:0]) : 4'b0000;
    assign dmem_wmask = (mem_start && issue_payload.mem_write)
                        ? (size_mask << alu_f[1:0]) : 4'b0000;
    assign dmem_wdata = prf_rs2_value << {alu_f[1:0], 3'b000};

    // The returned word, shifted down to the addressed lane and extended.
    logic [31:0] load_word, load_data;

    assign load_word = dmem_rdata >> {mem_byte_off, 3'b000};

    always_comb begin
        unique case (load_f3_t'(mem_payload.funct3))
            load_f3_lb:  load_data = {{24{load_word[7]}},  load_word[7:0]};
            load_f3_lh:  load_data = {{16{load_word[15]}}, load_word[15:0]};
            load_f3_lw:  load_data = load_word;
            load_f3_lbu: load_data = {24'b0, load_word[7:0]};
            load_f3_lhu: load_data = {16'b0, load_word[15:0]};
            default:     load_data = load_word;
        endcase
    end

    // ------------------------------------------------------------------
    // arbitration
    // ------------------------------------------------------------------
    // mem, then mdu, then fast. The first two have already waited and cannot be
    // asked to wait again without losing the result; the fast path has not
    // started, so refusing it costs only a cycle.
    logic fast_can_go;
    assign fast_can_go = !mem_busy && !mdu_done;

    logic accept_fast, accept_div, accept_mem;

    assign accept_mem  = issue_valid && is_mem && !mem_busy && !mdu_done
                         && (issue_payload.rob_idx == rob_head_idx);
    assign accept_div  = issue_valid && is_div && !mdu_busy;
    assign accept_fast = issue_valid && !is_mem && !is_div && fast_can_go;

    assign mem_start    = accept_mem;
    assign issue_accept = accept_fast || accept_div || accept_mem;

    // ------------------------------------------------------------------
    // what goes on the bus
    // ------------------------------------------------------------------
    logic [31:0] fast_value;

    always_comb begin
        unique case (issue_payload.wb_sel)
            wb_alu:  fast_value = is_mul ? mul_result : alu_f;
            wb_pc4:  fast_value = issue_payload.pc + 32'd4;
            wb_imm:  fast_value = issue_payload.imm;
            wb_mem:  fast_value = '0;      // never taken: a load is not fast
        endcase
    end

    always_comb begin
        if (mem_busy) begin
            complete             = 1'b1;
            complete_idx         = mem_payload.rob_idx;
            complete_mispredict  = 1'b0;
            complete_redirect_pc = 32'd0;
            wb_valid             = mem_payload.writes_reg;
            wb_tag               = mem_payload.rd_phys;
            wb_value             = load_data;
        end else if (mdu_done) begin
            complete             = 1'b1;
            complete_idx         = mdu_payload.rob_idx;
            complete_mispredict  = 1'b0;
            complete_redirect_pc = 32'd0;
            wb_valid             = mdu_payload.writes_reg;
            wb_tag               = mdu_payload.rd_phys;
            wb_value             = mdu_result;
        end else begin
            complete             = accept_fast;
            complete_idx         = issue_payload.rob_idx;
            complete_mispredict  = fast_mispredict;
            complete_redirect_pc = fast_redirect;
            wb_valid             = accept_fast && issue_payload.writes_reg;
            wb_tag               = issue_payload.rd_phys;
            wb_value             = fast_value;
        end
    end

    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            mdu_busy <= 1'b0;
            mem_busy <= 1'b0;
        end else begin
            if (accept_div) begin
                mdu_busy    <= 1'b1;
                mdu_payload <= '{rob_idx:    issue_payload.rob_idx,
                                 rd_phys:    issue_payload.rd_phys,
                                 writes_reg: issue_payload.writes_reg,
                                 funct3:     issue_payload.funct3};
                mdu_a       <= prf_rs1_value;
                mdu_b       <= prf_rs2_value;
            end else if (mdu_done) begin
                mdu_busy <= 1'b0;
            end

            if (accept_mem) begin
                mem_busy     <= 1'b1;
                mem_payload  <= '{rob_idx:    issue_payload.rob_idx,
                                  rd_phys:    issue_payload.rd_phys,
                                  writes_reg: issue_payload.writes_reg,
                                  funct3:     issue_payload.funct3};
                mem_byte_off <= alu_f[1:0];
            end else if (mem_busy) begin
                mem_busy <= 1'b0;
            end
        end
    end

endmodule
