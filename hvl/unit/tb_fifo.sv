// fifo: the circular queue three out-of-order structures are built on.
//
// Two instances, because the reset behaviour is parameterised and the two
// modes have nothing in common at time zero: a plain queue comes up empty, and
// a free-list-shaped one comes up full of consecutive tags.
//
// The cases worth the effort here are the ones that only appear at the
// boundaries -- wraparound, and a simultaneous push and pop when the queue is
// full or empty. A FIFO that is wrong only on wrap looks perfect until the
// first program long enough to reach it.

module tb_fifo;

    `include "tb_check.svh"

    localparam int unsigned DEPTH = 8;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    // ---- a plain queue -------------------------------------------------
    logic        q_push, q_pop, q_full, q_empty;
    logic [31:0] q_push_data, q_pop_data;
    logic [3:0]  q_count;

    fifo #(.WIDTH(32), .DEPTH(DEPTH)) q (
        .clk(clk), .rst(rst),
        .push(q_push), .push_data(q_push_data),
        .pop(q_pop), .pop_data(q_pop_data),
        .full(q_full), .empty(q_empty), .count(q_count));

    // ---- shaped like the free list it exists for -----------------------
    // 32 physical tags numbered 32..63, which is what is left over once the
    // architectural registers own 0..31.
    logic       f_push, f_pop, f_full, f_empty;
    logic [5:0] f_push_data, f_pop_data;
    logic [5:0] f_count;

    fifo #(.WIDTH(6), .DEPTH(32), .INIT_FULL(1'b1), .INIT_BASE(32)) f (
        .clk(clk), .rst(rst),
        .push(f_push), .push_data(f_push_data),
        .pop(f_pop), .pop_data(f_pop_data),
        .full(f_full), .empty(f_empty), .count(f_count));

    // ------------------------------------------------------------------
    // One clock with the given controls. Set just after a negedge, sampled by
    // the posedge, observed at the negedge after that -- so once this returns,
    // the cycle it describes has happened and the outputs have settled.
    task automatic q_cycle(bit do_push, logic [31:0] data, bit do_pop);
        q_push      = do_push;
        q_push_data = data;
        q_pop       = do_pop;
        @(negedge clk);
        q_push = 1'b0;
        q_pop  = 1'b0;
    endtask

    task automatic f_cycle(bit do_push, logic [5:0] data, bit do_pop);
        f_push      = do_push;
        f_push_data = data;
        f_pop       = do_pop;
        @(negedge clk);
        f_push = 1'b0;
        f_pop  = 1'b0;
    endtask

    task automatic reset_all();
        rst    = 1'b1;
        q_push = 1'b0; q_pop = 1'b0; q_push_data = '0;
        f_push = 1'b0; f_pop = 1'b0; f_push_data = '0;
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    int unsigned seen;

    initial begin
        reset_all();

        // ---- a plain queue comes up empty ------------------------------
        expect_bit("reset: empty",     q_empty, 1'b1);
        expect_bit("reset: not full",  q_full,  1'b0);
        expect_eq ("reset: count 0",   {28'd0, q_count}, 32'd0);

        // ---- one in, one out -------------------------------------------
        q_cycle(1'b1, 32'hdead_beef, 1'b0);
        expect_bit("after push: not empty", q_empty, 1'b0);
        expect_eq ("after push: count 1",   {28'd0, q_count}, 32'd1);
        expect_eq ("head is what went in",  q_pop_data, 32'hdead_beef);

        q_cycle(1'b0, 32'd0, 1'b1);
        expect_bit("after pop: empty",  q_empty, 1'b1);
        expect_eq ("after pop: count 0", {28'd0, q_count}, 32'd0);

        // ---- order is first in, first out ------------------------------
        for (int i = 0; i < 4; i++) begin
            q_cycle(1'b1, 32'h100 + i, 1'b0);
        end
        expect_eq("four pushed", {28'd0, q_count}, 32'd4);
        for (int i = 0; i < 4; i++) begin
            expect_eq("fifo order", q_pop_data, 32'h100 + i);
            q_cycle(1'b0, 32'd0, 1'b1);
        end
        expect_bit("drained", q_empty, 1'b1);

        // ---- fills to exactly DEPTH, and no further ---------------------
        for (int i = 0; i < int'(DEPTH); i++) begin
            q_cycle(1'b1, 32'h200 + i, 1'b0);
        end
        expect_bit("full at DEPTH",    q_full,  1'b1);
        expect_bit("full is not empty", q_empty, 1'b0);
        expect_eq ("count is DEPTH",   {28'd0, q_count}, DEPTH);

        // A push into a full queue is dropped, and must not corrupt the head.
        q_cycle(1'b1, 32'hbad0_bad0, 1'b0);
        expect_eq ("push when full ignored", {28'd0, q_count}, DEPTH);
        expect_eq ("head unchanged",         q_pop_data, 32'h200);

        // ---- drain, and confirm the dropped push never appeared ---------
        for (int i = 0; i < int'(DEPTH); i++) begin
            expect_eq("order survived filling", q_pop_data, 32'h200 + i);
            q_cycle(1'b0, 32'd0, 1'b1);
        end
        expect_bit("empty again", q_empty, 1'b1);

        // A pop from an empty queue is ignored rather than moving the pointer
        // backwards -- which would make the queue silently appear full.
        q_cycle(1'b0, 32'd0, 1'b1);
        expect_bit("pop when empty ignored", q_empty, 1'b1);
        expect_eq ("count still 0",          {28'd0, q_count}, 32'd0);

        // ---- push and pop in the same cycle, empty ----------------------
        // Nothing to pop, so the push simply lands.
        q_cycle(1'b1, 32'h3333_3333, 1'b1);
        expect_eq ("simultaneous on empty: count 1", {28'd0, q_count}, 32'd1);
        expect_eq ("simultaneous on empty: value",   q_pop_data, 32'h3333_3333);
        q_cycle(1'b0, 32'd0, 1'b1);

        // ---- push and pop in the same cycle, full -----------------------
        // The pop makes room, so the push must succeed and occupancy holds.
        for (int i = 0; i < int'(DEPTH); i++) begin
            q_cycle(1'b1, 32'h400 + i, 1'b0);
        end
        expect_bit("full before the pair", q_full, 1'b1);
        q_cycle(1'b1, 32'h4ff, 1'b1);
        expect_bit("still full after",  q_full, 1'b1);
        expect_eq ("count held at DEPTH", {28'd0, q_count}, DEPTH);
        expect_eq ("oldest was consumed", q_pop_data, 32'h401);

        // The value pushed during that pair must be the last one out.
        for (int i = 1; i < int'(DEPTH); i++) begin
            q_cycle(1'b0, 32'd0, 1'b1);
        end
        expect_eq("pushed-while-full value is last", q_pop_data, 32'h4ff);
        q_cycle(1'b0, 32'd0, 1'b1);
        expect_bit("drained after the pair", q_empty, 1'b1);

        // ---- wraparound --------------------------------------------------
        // Three times round the ring, one in and one out per cycle, checking
        // the value every time. This is the case a wrong full/empty scheme
        // survives everything else to fail.
        q_cycle(1'b1, 32'h5000, 1'b0);
        seen = 32'h5000;
        for (int i = 1; i < 3 * int'(DEPTH) + 3; i++) begin
            expect_eq("wrap keeps order", q_pop_data, seen);
            q_cycle(1'b1, 32'h5000 + i, 1'b1);
            seen = 32'h5000 + i;
            expect_eq("wrap holds one entry", {28'd0, q_count}, 32'd1);
        end
        q_cycle(1'b0, 32'd0, 1'b1);
        expect_bit("empty after the wrap run", q_empty, 1'b1);

        // ---- INIT_FULL: the free list's reset state ----------------------
        expect_bit("init_full: full",      f_full,  1'b1);
        expect_bit("init_full: not empty", f_empty, 1'b0);
        expect_eq ("init_full: count",     {26'd0, f_count}, 32'd32);

        // Tags come out in order starting at INIT_BASE. A free list that
        // handed out the same tag twice, or one already in use, would break
        // rename in a way that is very hard to see from a program.
        for (int i = 0; i < 32; i++) begin
            expect_eq("init_full tag order", {26'd0, f_pop_data}, 32'd32 + i);
            f_cycle(1'b0, 6'd0, 1'b1);
        end
        expect_bit("init_full: empties",  f_empty, 1'b1);
        expect_eq ("init_full: count 0",  {26'd0, f_count}, 32'd0);

        // Freed tags come back and are handed out again, which is the whole
        // lifecycle the free list needs.
        f_cycle(1'b1, 6'd40, 1'b0);
        f_cycle(1'b1, 6'd33, 1'b0);
        expect_eq("returned tag comes back", {26'd0, f_pop_data}, 32'd40);
        f_cycle(1'b0, 6'd0, 1'b1);
        expect_eq("and then the next",       {26'd0, f_pop_data}, 32'd33);

        // ---- reset from a non-empty state --------------------------------
        // Reset has to restore the initial contents, not merely the pointers.
        reset_all();
        expect_bit("re-reset: plain empty",   q_empty, 1'b1);
        expect_bit("re-reset: init_full full", f_full, 1'b1);
        expect_eq ("re-reset: first tag",     {26'd0, f_pop_data}, 32'd32);

        report("fifo");
    end

endmodule
