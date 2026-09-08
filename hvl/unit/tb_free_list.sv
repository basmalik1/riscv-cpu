// free_list: the pool of physical register tags.
//
// The module is thin, so most of these checks are not about its ten lines of
// wiring. They are about the one property the rest of the machine cannot
// survive being wrong: if a tag is handed out while another instruction still
// holds it, two instructions write the same physical register and the older
// result is silently replaced. Nothing downstream can detect that. It surfaces
// as a wrong value in a program, arbitrarily far from the cause.
//
// So the substance here is a scoreboard rather than a directed case -- a long
// interleaved run of allocates and frees, checking on every allocate that the
// tag was not already outstanding, and on every free that it was.

module tb_free_list;

    `include "tb_check.svh"

    localparam int unsigned PHYS  = 64;
    localparam int unsigned ARCH  = 32;
    localparam int unsigned DEPTH = PHYS - ARCH;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    logic       alloc, alloc_valid, free, full;
    logic [5:0] alloc_tag, free_tag;
    logic [5:0] count;

    free_list #(.PHYS_REGS(PHYS), .ARCH_REGS(ARCH)) dut (.*);

    // What this testbench believes is outstanding, and in what order it was
    // taken. The bit array answers "is this tag held"; the queue is only a
    // convenient source of something legal to hand back.
    bit         held [PHYS];
    logic [5:0] held_q [$];

    // One cycle. Inputs are driven, the combinational outputs are sampled
    // before the edge that consumes them, then the clock advances.
    task automatic step(bit do_alloc, bit do_free, logic [5:0] ftag,
                        output logic [5:0] got_tag, output bit got_valid);
        alloc     = do_alloc;
        free      = do_free;
        free_tag  = ftag;
        #1;
        got_valid = alloc_valid;
        got_tag   = alloc_tag;
        @(negedge clk);
        alloc = 1'b0;
        free  = 1'b0;
    endtask

    // An allocate, with both invariants checked on the spot.
    task automatic take(output logic [5:0] t);
        bit ok;
        step(1'b1, 1'b0, 6'd0, t, ok);
        checks_run = checks_run + 1;
        if (!ok) begin
            checks_failed = checks_failed + 1;
            $display("  FAIL %-38s pool was unexpectedly empty", "allocate");
        end else if (t < 6'(ARCH)) begin
            checks_failed = checks_failed + 1;
            $display("  FAIL %-38s tag %0d is architectural", "allocate", t);
        end else if (held[t]) begin
            checks_failed = checks_failed + 1;
            $display("  FAIL %-38s tag %0d was already outstanding", "allocate", t);
        end else begin
            held[t] = 1'b1;
            held_q.push_back(t);
        end
    endtask

    task automatic give(logic [5:0] t);
        logic [5:0] ignored_tag;
        bit         ignored_v;
        checks_run = checks_run + 1;
        if (!held[t]) begin
            checks_failed = checks_failed + 1;
            $display("  FAIL %-38s freeing tag %0d that is not held", "free", t);
        end
        held[t] = 1'b0;
        step(1'b0, 1'b1, t, ignored_tag, ignored_v);
    endtask

    task automatic reset_dut();
        rst = 1'b1; alloc = 1'b0; free = 1'b0; free_tag = '0;
        for (int i = 0; i < int'(PHYS); i++) begin
            held[i] = 1'b0;
        end
        held_q.delete();
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    logic [5:0] t, t2;
    bit         v;
    int         idx;

    initial begin
        reset_dut();

        // ---- reset: every non-architectural tag is available --------------
        expect_eq ("reset: count is PHYS - ARCH", {26'd0, count}, DEPTH);
        expect_bit("reset: a tag is available",   alloc_valid, 1'b1);
        expect_bit("reset: pool is full",         full, 1'b1);
        expect_eq ("reset: first tag is ARCH",    {26'd0, alloc_tag}, ARCH);

        // ---- drain the whole pool -----------------------------------------
        for (int i = 0; i < int'(DEPTH); i++) begin
            expect_eq("count while draining", {26'd0, count}, DEPTH - i);
            take(t);
        end
        expect_eq ("drained: count 0",           {26'd0, count}, 32'd0);
        expect_bit("drained: nothing available", alloc_valid, 1'b0);
        expect_bit("drained: not full",          full, 1'b0);

        // An allocate against an empty pool must change nothing. Rename is
        // expected to have stalled; the danger is a pool that hands out a
        // stale tag anyway and lets two instructions share a register.
        step(1'b1, 1'b0, 6'd0, t, v);
        expect_bit("empty: allocate refused", v, 1'b0);
        expect_eq ("empty: count still 0",    {26'd0, count}, 32'd0);

        // ---- hand them all back -------------------------------------------
        for (int i = 0; i < int'(DEPTH); i++) begin
            t = held_q.pop_front();
            give(t);
        end
        expect_eq ("returned: count back to DEPTH", {26'd0, count}, DEPTH);
        expect_bit("returned: full again",          full, 1'b1);

        // ---- a freed tag is not lost ---------------------------------------
        reset_dut();
        take(t);
        give(t);
        expect_eq("freed tag returns to the pool", {26'd0, count}, DEPTH);

        // ---- allocate and free in the same cycle ---------------------------
        // The steady state during execution: rename takes one while commit
        // hands one back, every cycle, indefinitely.
        reset_dut();
        take(t);
        for (int i = 0; i < 200; i++) begin
            logic [5:0] give_tag;
            give_tag       = held_q.pop_front();
            held[give_tag] = 1'b0;

            alloc    = 1'b1;
            free     = 1'b1;
            free_tag = give_tag;
            #1;
            checks_run = checks_run + 1;
            if (!alloc_valid) begin
                checks_failed = checks_failed + 1;
                $display("  FAIL %-38s pool ran dry in steady state", "alloc+free");
            end else if (held[alloc_tag]) begin
                checks_failed = checks_failed + 1;
                $display("  FAIL %-38s reissued outstanding tag %0d",
                         "alloc+free", alloc_tag);
            end else begin
                held[alloc_tag] = 1'b1;
                held_q.push_back(alloc_tag);
            end
            @(negedge clk);
            alloc = 1'b0;
            free  = 1'b0;
        end
        expect_eq("steady state holds occupancy", {26'd0, count}, DEPTH - 1);

        // ---- a long random interleaving -------------------------------------
        // Allocate or free at random, and check both invariants every time.
        reset_dut();
        for (int i = 0; i < 3000; i++) begin
            bit want_alloc;
            want_alloc = ($urandom_range(0, 1) == 0);

            if (want_alloc && alloc_valid) begin
                take(t);
            end else if (held_q.size() > 0) begin
                idx = $urandom_range(0, held_q.size() - 1);
                t2  = held_q[idx];
                held_q.delete(idx);
                give(t2);
            end else begin
                @(negedge clk);
            end
        end

        // Occupancy has to add up: what the pool says it holds plus what this
        // testbench is holding is the whole pool. A tag lost anywhere in that
        // run shows here and nowhere else.
        expect_eq("no tags leaked or duplicated",
                  {26'd0, count} + 32'(held_q.size()), DEPTH);

        // Draining from wherever the random run left it must yield exactly the
        // tags nobody holds, all of them distinct.
        //
        // Bounded on purpose. An unbounded `while (alloc_valid)` here hangs
        // rather than fails if the pool ever stops draining -- which is not
        // hypothetical: it is exactly what a mis-wired queue does, and it cost
        // a mutation run that reported the resulting hang as a clean pass.
        for (int i = 0; i <= int'(DEPTH) && alloc_valid; i++) begin
            take(t);
        end
        expect_bit("drain terminates", alloc_valid, 1'b0);
        expect_eq("everything accounted for after drain",
                  32'(held_q.size()), DEPTH);
        expect_eq("pool empty after drain", {26'd0, count}, 32'd0);

        report("free_list");
    end

endmodule
