// execute: the three paths, and the one property the iteration exists for.
//
// A 34-cycle divide must NOT stop the machine. If it did, the out-of-order core
// would stall exactly where the pipelined one stalls and the whole iteration
// would have bought nothing. So the central test starts a divide and then
// keeps feeding arithmetic past it, counting how much got through before the
// divide finished. That number is the iteration's entire thesis expressed as a
// check.
//
// The rest is the parts that are easy to get subtly wrong: which path wins the
// single result bus, that a memory operation waits until it is the oldest
// instruction in the machine, and that a taken branch reports itself as a
// misprediction when there is no predictor to have been right.

module tb_execute
import rv32i_types::*;
import ooo_types::*;
;

    `include "tb_check.svh"

    logic clk = 1'b0;
    logic rst, flush;

    always #5 clk = ~clk;

    logic        issue_valid, issue_accept;
    iq_payload_t issue_payload;

    logic [5:0]  prf_rs1_tag, prf_rs2_tag;
    logic [31:0] prf_rs1_value, prf_rs2_value;

    logic [4:0]  rob_head_idx;
    logic        complete, complete_mispredict;
    logic [4:0]  complete_idx;
    logic [31:0] complete_redirect_pc;

    logic        wb_valid;
    logic [5:0]  wb_tag;
    logic [31:0] wb_value;

    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_rmask, dmem_wmask;

    execute dut (.*);

    // A tiny register file: whatever tag is asked for reads back as its own
    // number times 0x100, unless overridden. Enough to tell operands apart.
    logic [31:0] regs [64];
    assign prf_rs1_value = regs[prf_rs1_tag];
    assign prf_rs2_value = regs[prf_rs2_tag];

    // Synchronous read, matching what the core will actually be given.
    logic [31:0] mem [64];
    always_ff @(posedge clk) begin
        dmem_rdata <= mem[dmem_addr[7:2]];
        for (int i = 0; i < 4; i++) begin
            if (dmem_wmask[i]) begin
                mem[dmem_addr[7:2]][8*i +: 8] <= dmem_wdata[8*i +: 8];
            end
        end
    end

    // ------------------------------------------------------------------
    function automatic iq_payload_t mk(
        logic [4:0] rob_idx, logic [5:0] rd, bit writes,
        logic [5:0] r1, logic [5:0] r2,
        logic [31:0] pc, logic [31:0] imm,
        alu_ops op, alu_a_sel_t asel, alu_b_sel_t bsel, wb_sel_t wsel,
        logic [2:0] f3);
        mk            = '0;
        mk.rob_idx    = rob_idx;
        mk.rd_phys    = rd;
        mk.writes_reg = writes;
        mk.rs1_phys   = r1;
        mk.rs2_phys   = r2;
        mk.pc         = pc;
        mk.imm        = imm;
        mk.aluop      = op;
        mk.alu_a_sel  = asel;
        mk.alu_b_sel  = bsel;
        mk.wb_sel     = wsel;
        mk.funct3     = f3;
    endfunction

    // An ordinary add of two registers.
    function automatic iq_payload_t mk_add(logic [4:0] idx, logic [5:0] rd,
                                           logic [5:0] r1, logic [5:0] r2);
        mk_add = mk(idx, rd, 1'b1, r1, r2, 32'h8000_0000, 32'd0,
                    alu_op_add, alu_a_rs1, alu_b_rs2, wb_alu, 3'b000);
    endfunction

    int completed;

    task automatic tick();
        #1;
        if (complete) begin
            completed = completed + 1;
        end
        @(negedge clk);
    endtask

    task automatic reset_dut();
        rst = 1'b1; flush = 1'b0;
        issue_valid = 1'b0;
        issue_payload = '0;
        rob_head_idx = 5'd0;
        completed = 0;
        for (int i = 0; i < 64; i++) begin
            regs[i] = 32'(i) * 32'h100;
            mem[i]  = 32'hA000_0000 + 32'(i);
        end
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    int alu_through;
    logic [31:0] seen;

    initial begin
        reset_dut();

        // ---- an ordinary add resolves in the cycle it issues ---------------
        issue_payload = mk_add(5'd3, 6'd40, 6'd5, 6'd6);
        issue_valid   = 1'b1;
        #1;
        expect_bit("add is accepted",          issue_accept, 1'b1);
        expect_bit("add completes at once",    complete,     1'b1);
        expect_eq ("add completes the right entry", {27'd0, complete_idx}, 32'd3);
        expect_bit("add broadcasts",           wb_valid,     1'b1);
        expect_eq ("add writes the right tag",  {26'd0, wb_tag}, 32'd40);
        expect_eq ("add computes rs1 + rs2",   wb_value, 32'h500 + 32'h600);
        expect_bit("add is not a mispredict",  complete_mispredict, 1'b0);
        tick();

        // ---- a not-taken branch is not a mispredict --------------------------
        // beq with unequal operands. Fetch ran straight ahead, which is what
        // happened, so there is nothing to correct.
        regs[6'd5] = 32'd7;
        regs[6'd6] = 32'd9;
        issue_payload = mk(5'd4, 6'd0, 1'b0, 6'd5, 6'd6, 32'h8000_0100, 32'd16,
                           alu_op_add, alu_a_pc, alu_b_imm, wb_alu, 3'b000);
        issue_payload.is_branch = 1'b1;
        #1;
        expect_bit("not-taken branch completes", complete, 1'b1);
        expect_bit("and is not a mispredict",    complete_mispredict, 1'b0);
        expect_bit("and writes no register",     wb_valid, 1'b0);
        tick();

        // ---- a taken branch IS a mispredict ----------------------------------
        // There is no predictor, so fetch predicted not-taken by construction
        // and every taken branch has to be corrected.
        regs[6'd6] = 32'd7;
        #1;
        expect_bit("taken branch is a mispredict", complete_mispredict, 1'b1);
        expect_eq ("and redirects to pc + imm",
                   complete_redirect_pc, 32'h8000_0110);
        tick();

        // ---- jal always redirects, and links pc + 4 ---------------------------
        issue_payload = mk(5'd5, 6'd41, 1'b1, 6'd0, 6'd0, 32'h8000_0200, 32'd12,
                           alu_op_add, alu_a_pc, alu_b_imm, wb_pc4, 3'b000);
        issue_payload.is_jal = 1'b1;
        #1;
        expect_bit("jal is always a mispredict", complete_mispredict, 1'b1);
        expect_eq ("jal target",                 complete_redirect_pc, 32'h8000_020c);
        expect_eq ("jal links pc + 4",           wb_value, 32'h8000_0204);
        tick();

        // ---- jalr clears bit 0 -------------------------------------------------
        // An odd target is the only thing that shows a missing mask.
        regs[6'd7] = 32'h8000_0300;
        issue_payload = mk(5'd6, 6'd42, 1'b1, 6'd7, 6'd0, 32'h8000_0280, 32'd1,
                           alu_op_add, alu_a_rs1, alu_b_imm, wb_pc4, 3'b000);
        issue_payload.is_jalr = 1'b1;
        #1;
        expect_eq("jalr clears bit 0", complete_redirect_pc, 32'h8000_0300);
        tick();

        // ---- a multiply is on the fast path -----------------------------------
        // It resolves combinationally, so it must complete in the cycle it
        // issues just like an add, not occupy the divider.
        reset_dut();
        regs[6'd5] = 32'd6;
        regs[6'd6] = 32'd7;
        issue_payload = mk(5'd1, 6'd43, 1'b1, 6'd5, 6'd6, 32'h8000_0000, 32'd0,
                           alu_op_add, alu_a_rs1, alu_b_rs2, wb_alu, 3'b000);
        issue_payload.is_muldiv = 1'b1;
        issue_payload.funct3    = 3'b000;      // mul
        issue_valid = 1'b1;
        #1;
        expect_bit("multiply is accepted",      issue_accept, 1'b1);
        expect_bit("multiply completes at once", complete,    1'b1);
        expect_eq ("multiply result",           wb_value,     32'd42);
        tick();

        // ================================================================
        // THE PROPERTY THE ITERATION EXISTS FOR
        // ================================================================
        // Start a divide, then keep offering adds. The divide must occupy only
        // the divider, and the arithmetic must keep completing past it. If this
        // count came out at zero the core would be stalling exactly where the
        // pipelined one stalls.
        reset_dut();
        regs[6'd5] = 32'd100;
        regs[6'd6] = 32'd7;
        issue_payload = mk(5'd1, 6'd44, 1'b1, 6'd5, 6'd6, 32'h8000_0000, 32'd0,
                           alu_op_add, alu_a_rs1, alu_b_rs2, wb_alu, 3'b000);
        issue_payload.is_muldiv = 1'b1;
        issue_payload.funct3    = 3'b101;      // divu
        issue_valid = 1'b1;
        #1;
        expect_bit("divide is accepted", issue_accept, 1'b1);
        @(negedge clk);

        // Now hammer it with adds until the divide reports back.
        alu_through = 0;
        issue_payload = mk_add(5'd2, 6'd45, 6'd5, 6'd6);
        for (int i = 0; i < 60; i++) begin
            #1;
            if (complete && complete_idx == 5'd1) begin
                seen = wb_value;
                // The bus carries the divide this cycle, so the add being
                // offered must be REFUSED. Accepting it would take it out of
                // the issue queue while the result mux is broadcasting
                // something else -- the instruction would vanish, with no
                // record anywhere that it ever issued.
                expect_bit("the add is refused on the divide's broadcast cycle",
                           issue_accept, 1'b0);
                i    = 60;                    // the divide landed; stop
            end else begin
                if (issue_accept && complete && complete_idx == 5'd2) begin
                    alu_through = alu_through + 1;
                end
                @(negedge clk);
            end
        end

        expect_eq ("the divide produced the right quotient", seen, 32'd14);
        // 100/7 takes the divider 34 cycles. Anything close to that many adds
        // getting through means the machine kept working; zero would mean it
        // stalled like the pipelined core does.
        expect_bit("arithmetic kept issuing during the divide",
                   (alu_through > 25), 1'b1);
        $display("  (%0d adds completed while the divide ran)", alu_through);

        // ---- the divider is busy, so a second divide waits ---------------------
        reset_dut();
        issue_payload = mk(5'd1, 6'd44, 1'b1, 6'd5, 6'd6, 32'h8000_0000, 32'd0,
                           alu_op_add, alu_a_rs1, alu_b_rs2, wb_alu, 3'b000);
        issue_payload.is_muldiv = 1'b1;
        issue_payload.funct3    = 3'b101;
        issue_valid = 1'b1;
        #1;
        expect_bit("first divide accepted", issue_accept, 1'b1);
        @(negedge clk);
        #1;
        expect_bit("second divide refused while the first runs",
                   issue_accept, 1'b0);

        // ---- memory waits until it is the oldest instruction --------------------
        reset_dut();
        regs[6'd5] = 32'd8;                   // address 8 -> word 2
        issue_payload = mk(5'd4, 6'd46, 1'b1, 6'd5, 6'd0, 32'h8000_0000, 32'd0,
                           alu_op_add, alu_a_rs1, alu_b_imm, wb_mem, 3'b010);
        issue_payload.mem_read = 1'b1;
        issue_valid  = 1'b1;
        rob_head_idx = 5'd0;                  // something older is still in front
        #1;
        expect_bit("a load that is not oldest is refused", issue_accept, 1'b0);
        expect_bit("and touches no memory",                dmem_rmask == 4'b0000, 1'b1);

        rob_head_idx = 5'd4;                  // now it is the oldest
        #1;
        expect_bit("a load that IS oldest is accepted", issue_accept, 1'b1);
        expect_bit("and reads memory",                  dmem_rmask != 4'b0000, 1'b1);
        expect_eq ("at the right address",  dmem_addr, 32'd8);
        @(negedge clk);

        // The data comes back the cycle after, because the read is synchronous.
        #1;
        expect_bit("the load completes a cycle later", complete, 1'b1);
        expect_eq ("with the right rob entry",  {27'd0, complete_idx}, 32'd4);
        expect_eq ("and the word from memory",  wb_value, 32'hA000_0002);
        expect_bit("and it broadcasts",         wb_valid, 1'b1);
        @(negedge clk);

        // ---- a store writes memory and broadcasts nothing -----------------------
        reset_dut();
        regs[6'd5] = 32'd12;                  // address 12 -> word 3
        regs[6'd6] = 32'hCAFE_F00D;
        issue_payload = mk(5'd0, 6'd0, 1'b0, 6'd5, 6'd6, 32'h8000_0000, 32'd0,
                           alu_op_add, alu_a_rs1, alu_b_imm, wb_alu, 3'b010);
        issue_payload.mem_write = 1'b1;
        issue_valid  = 1'b1;
        rob_head_idx = 5'd0;
        #1;
        expect_bit("store accepted at the head", issue_accept, 1'b1);
        expect_eq ("store mask is a full word",  {28'd0, dmem_wmask}, 32'hf);
        @(negedge clk);
        #1;
        expect_bit("store completes",            complete, 1'b1);
        expect_bit("store broadcasts nothing",   wb_valid, 1'b0);
        @(negedge clk);
        expect_eq("store reached memory", mem[3], 32'hCAFE_F00D);

        // ---- flush clears both busy paths ----------------------------------------
        reset_dut();
        issue_payload = mk(5'd1, 6'd44, 1'b1, 6'd5, 6'd6, 32'h8000_0000, 32'd0,
                           alu_op_add, alu_a_rs1, alu_b_rs2, wb_alu, 3'b000);
        issue_payload.is_muldiv = 1'b1;
        issue_payload.funct3    = 3'b101;
        issue_valid = 1'b1;
        @(negedge clk);
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;
        issue_payload.funct3 = 3'b101;
        #1;
        expect_bit("a divide can start again after a flush", issue_accept, 1'b1);

        report("execute");
    end

endmodule
