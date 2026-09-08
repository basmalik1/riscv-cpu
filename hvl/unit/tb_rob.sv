// rob: in-order commit over out-of-order completion, and recovery.
//
// The defining property is that instructions leave in the order they arrived
// no matter what order they finish in. A reorder buffer that committed things
// as they completed would still pass every test that finishes them in order,
// so the central case here deliberately completes them backwards.
//
// The second property is which physical register is released, and when. A
// COMMITTED instruction releases the one it DISPLACED, because its own now
// holds architectural state. A SQUASHED one releases its OWN, because it never
// became architectural. Getting those two the wrong way round frees a register
// the machine is still using, and the damage lands on whichever instruction is
// handed it next -- arbitrarily far away, with nothing to connect the two.

module tb_rob;

    `include "tb_check.svh"

    localparam int unsigned DEPTH = 32;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    logic        alloc, alloc_writes_reg, alloc_is_halt, alloc_ready;
    logic [4:0]  alloc_rd_arch;
    logic [5:0]  alloc_rd_phys, alloc_rd_old_phys;
    logic [31:0] alloc_pc;
    logic [4:0]  alloc_idx;
    logic [4:0]  head_idx;

    logic        complete, complete_mispredict;
    logic [4:0]  complete_idx;
    logic [31:0] complete_redirect_pc;

    logic        commit, commit_writes_reg, commit_halt;
    logic [4:0]  commit_rd_arch;
    logic [5:0]  commit_rd_phys;
    logic [31:0] commit_pc;

    logic        flush;
    logic [31:0] flush_pc;
    logic        free_valid;
    logic [5:0]  free_phys;
    logic        empty, full;

    rob #(.DEPTH(DEPTH), .PHYS_REGS(64), .ARCH_REGS(32)) dut (.*);

    // What has come out, in the order it came out.
    logic [31:0] committed_pc [$];
    logic [5:0]  freed        [$];

    task automatic settle();
        #1;
    endtask

    // Advance one cycle, recording anything the ROB emitted during it.
    task automatic tick();
        settle();
        if (commit) begin
            committed_pc.push_back(commit_pc);
        end
        if (free_valid) begin
            freed.push_back(free_phys);
        end
        @(negedge clk);
    endtask

    task automatic do_alloc(logic [4:0] a, logic [5:0] p, logic [5:0] old,
                            bit writes, logic [31:0] pc, bit halt,
                            output logic [4:0] idx);
        alloc             = 1'b1;
        alloc_rd_arch     = a;
        alloc_rd_phys     = p;
        alloc_rd_old_phys = old;
        alloc_writes_reg  = writes;
        alloc_pc          = pc;
        alloc_is_halt     = halt;
        settle();
        idx = alloc_idx;
        if (commit) begin
            committed_pc.push_back(commit_pc);
        end
        if (free_valid) begin
            freed.push_back(free_phys);
        end
        @(negedge clk);
        alloc = 1'b0;
    endtask

    task automatic do_complete(logic [4:0] idx, bit mispred, logic [31:0] rpc);
        complete             = 1'b1;
        complete_idx         = idx;
        complete_mispredict  = mispred;
        complete_redirect_pc = rpc;
        settle();
        if (commit) begin
            committed_pc.push_back(commit_pc);
        end
        if (free_valid) begin
            freed.push_back(free_phys);
        end
        @(negedge clk);
        complete = 1'b0;
    endtask

    task automatic reset_dut();
        rst = 1'b1;
        alloc = 1'b0; complete = 1'b0;
        alloc_rd_arch = '0; alloc_rd_phys = '0; alloc_rd_old_phys = '0;
        alloc_writes_reg = 1'b0; alloc_pc = '0; alloc_is_halt = 1'b0;
        complete_idx = '0; complete_mispredict = 1'b0; complete_redirect_pc = '0;
        committed_pc.delete();
        freed.delete();
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    logic [4:0] i0, i1, i2, i3, ix;

    initial begin
        reset_dut();

        // ---- reset -----------------------------------------------------
        expect_bit("reset: empty",        empty, 1'b1);
        expect_bit("reset: not full",     full,  1'b0);
        expect_bit("reset: can allocate", alloc_ready, 1'b1);
        expect_bit("reset: not committing", commit, 1'b0);
        expect_bit("reset: not flushing",   flush,  1'b0);

        // ---- an incomplete instruction does not commit -------------------
        do_alloc(5'd1, 6'd40, 6'd1, 1'b1, 32'h8000_0000, 1'b0, i0);
        expect_bit("allocated: not empty",   empty, 1'b0);
        expect_bit("not done, so no commit", commit, 1'b0);
        tick();
        tick();
        expect_eq("still nothing committed", 32'(committed_pc.size()), 32'd0);

        // ---- completing it lets it commit --------------------------------
        do_complete(i0, 1'b0, 32'd0);
        settle();
        expect_bit("done, so commit",         commit, 1'b1);
        expect_eq ("commit reports its pc",   commit_pc, 32'h8000_0000);
        expect_eq ("commit reports rd_arch",  {27'd0, commit_rd_arch}, 32'd1);
        expect_eq ("commit reports rd_phys",  {26'd0, commit_rd_phys}, 32'd40);
        // The DISPLACED register is what goes back, not this instruction's own.
        expect_bit("commit frees something",  free_valid, 1'b1);
        expect_eq ("commit frees the displaced register",
                   {26'd0, free_phys}, 32'd1);
        tick();
        expect_bit("empty after commit", empty, 1'b1);

        // ---- IN-ORDER COMMIT over OUT-OF-ORDER COMPLETION ----------------
        // Three instructions, completed backwards. They must still leave in
        // the order they arrived. A buffer that retired things as they
        // finished passes every in-order test and fails only this one.
        reset_dut();
        do_alloc(5'd1, 6'd40, 6'd1, 1'b1, 32'hA000_0000, 1'b0, i0);
        do_alloc(5'd2, 6'd41, 6'd2, 1'b1, 32'hA000_0004, 1'b0, i1);
        do_alloc(5'd3, 6'd42, 6'd3, 1'b1, 32'hA000_0008, 1'b0, i2);

        do_complete(i2, 1'b0, 32'd0);
        expect_eq("youngest done first commits nothing",
                  32'(committed_pc.size()), 32'd0);
        do_complete(i1, 1'b0, 32'd0);
        expect_eq("middle done next commits nothing",
                  32'(committed_pc.size()), 32'd0);

        // Only when the OLDEST finishes does anything leave -- and then all
        // three drain, one per cycle, in arrival order.
        do_complete(i0, 1'b0, 32'd0);
        tick();
        tick();
        tick();
        expect_eq("all three committed", 32'(committed_pc.size()), 32'd3);
        if (committed_pc.size() == 3) begin
            expect_eq("commit order 1", committed_pc[0], 32'hA000_0000);
            expect_eq("commit order 2", committed_pc[1], 32'hA000_0004);
            expect_eq("commit order 3", committed_pc[2], 32'hA000_0008);
        end

        // ---- an instruction that writes no register frees nothing ---------
        reset_dut();
        do_alloc(5'd0, 6'd0, 6'd0, 1'b0, 32'hB000_0000, 1'b0, i0);
        do_complete(i0, 1'b0, 32'd0);
        settle();
        expect_bit("store commits",            commit, 1'b1);
        expect_bit("store frees no register",  free_valid, 1'b0);
        expect_bit("store writes no register", commit_writes_reg, 1'b0);
        tick();

        // ---- the halt flag rides through ----------------------------------
        reset_dut();
        do_alloc(5'd0, 6'd0, 6'd0, 1'b0, 32'hC000_0000, 1'b1, i0);
        do_complete(i0, 1'b0, 32'd0);
        settle();
        expect_bit("halt reported at commit", commit_halt, 1'b1);
        tick();

        // ---- fills to exactly DEPTH ---------------------------------------
        reset_dut();
        for (int i = 0; i < int'(DEPTH); i++) begin
            do_alloc(5'(i % 32), 6'(32 + (i % 32)), 6'(i % 32), 1'b1,
                     32'hD000_0000 + 32'(i) * 4, 1'b0, ix);
        end
        expect_bit("full at DEPTH",       full, 1'b1);
        expect_bit("full blocks allocate", alloc_ready, 1'b0);
        expect_bit("full is not empty",    empty, 1'b0);

        // ---- MISPREDICT and the squash walk --------------------------------
        // Four instructions. The second mispredicts. It must commit normally,
        // then everything behind it is squashed and each squashed entry hands
        // back its OWN physical register.
        reset_dut();
        do_alloc(5'd1, 6'd40, 6'd11, 1'b1, 32'hE000_0000, 1'b0, i0);
        do_alloc(5'd2, 6'd41, 6'd12, 1'b1, 32'hE000_0004, 1'b0, i1);
        do_alloc(5'd3, 6'd42, 6'd13, 1'b1, 32'hE000_0008, 1'b0, i2);
        do_alloc(5'd4, 6'd43, 6'd14, 1'b1, 32'hE000_000c, 1'b0, i3);

        do_complete(i0, 1'b0, 32'd0);
        do_complete(i1, 1'b1, 32'hFACE_0000);   // this one mispredicts
        do_complete(i2, 1'b0, 32'd0);
        do_complete(i3, 1'b0, 32'd0);

        // The first two commit normally, freeing what they displaced.
        tick();
        tick();
        tick();
        tick();
        tick();
        tick();

        expect_eq("two committed before the flush",
                  32'(committed_pc.size()), 32'd2);
        if (committed_pc.size() >= 2) begin
            expect_eq("the mispredicting one committed too",
                      committed_pc[1], 32'hE000_0004);
        end
        expect_bit("everything drained", empty, 1'b1);
        expect_bit("flush finished",     flush, 1'b0);
        expect_bit("allocation allowed again", alloc_ready, 1'b1);

        // Four registers returned: two displaced by the commits, two taken by
        // the squashed instructions.
        expect_eq("four registers returned", 32'(freed.size()), 32'd4);
        if (freed.size() == 4) begin
            expect_eq("commit 1 freed what it displaced", {26'd0, freed[0]}, 32'd11);
            expect_eq("commit 2 freed what it displaced", {26'd0, freed[1]}, 32'd12);
            expect_eq("squash 1 freed its own",           {26'd0, freed[2]}, 32'd42);
            expect_eq("squash 2 freed its own",           {26'd0, freed[3]}, 32'd43);
        end

        // ---- the flush target is the one that was recorded ------------------
        reset_dut();
        do_alloc(5'd1, 6'd40, 6'd11, 1'b1, 32'hE100_0000, 1'b0, i0);
        do_alloc(5'd2, 6'd41, 6'd12, 1'b1, 32'hE100_0004, 1'b0, i1);
        do_complete(i0, 1'b1, 32'hBEEF_0000);
        do_complete(i1, 1'b0, 32'd0);
        tick();                              // i0 commits, flush arms
        settle();
        expect_bit("flush asserted after the mispredict commits", flush, 1'b1);
        expect_eq ("flush target is what was recorded", flush_pc, 32'hBEEF_0000);
        expect_bit("allocation blocked during the walk", alloc_ready, 1'b0);
        tick();
        tick();
        expect_bit("walk finished", flush, 1'b0);

        // ---- a squashed instruction that wrote no register frees nothing -----
        reset_dut();
        do_alloc(5'd1, 6'd40, 6'd11, 1'b1, 32'hE200_0000, 1'b0, i0);
        do_alloc(5'd0, 6'd0,  6'd0,  1'b0, 32'hE200_0004, 1'b0, i1);
        do_complete(i0, 1'b1, 32'hCAFE_0000);
        tick();
        tick();
        tick();
        expect_eq("only the displaced register came back", 32'(freed.size()), 32'd1);
        if (freed.size() >= 1) begin
            expect_eq("and it was the displaced one", {26'd0, freed[0]}, 32'd11);
        end

        // ---- wraparound -------------------------------------------------------
        // Round the ring several times, one in and one out, checking order the
        // whole way. A reorder buffer wrong only on wrap looks perfect until a
        // program long enough to reach it.
        reset_dut();
        for (int i = 0; i < 3 * int'(DEPTH) + 5; i++) begin
            do_alloc(5'd1, 6'd40, 6'd20, 1'b1, 32'hF000_0000 + 32'(i) * 4, 1'b0, ix);
            do_complete(ix, 1'b0, 32'd0);
            tick();
        end
        expect_eq("wrap committed everything",
                  32'(committed_pc.size()), 3 * DEPTH + 5);
        if (committed_pc.size() == 3 * DEPTH + 5) begin
            expect_eq("wrap kept order at the start", committed_pc[0], 32'hF000_0000);
            expect_eq("wrap kept order at the end",
                      committed_pc[3 * DEPTH + 4],
                      32'hF000_0000 + (3 * DEPTH + 4) * 4);
        end

        report("rob");
    end

endmodule
