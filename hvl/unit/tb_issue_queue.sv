// issue_queue: wakeup, age-ordered selection, and the collapse.
//
// Two instances, because one of the bugs this is guarding against only exists
// when more than one result can be broadcast in a cycle. A wakeup written as a
// loop that ASSIGNS the ready bit per port rather than OR-ing across them makes
// the last port win: an entry woken by port 0 goes back to sleep because port 1
// did not match it. With a single port that is indistinguishable from correct,
// so a two-port instance is the only thing that can find it.
//
// The other case worth the effort is the one-cycle wakeup boundary. An entry
// woken in cycle N must become issuable in N+1 and NOT in N, because the value
// it is waiting for does not reach the register file until N ends. Both halves
// matter: issuing a cycle early reads stale data, and issuing a cycle late is
// a permanent throughput loss that no test of register contents would see.

module tb_issue_queue;

    `include "tb_check.svh"

    localparam int unsigned DEPTH = 8;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    // ---- single wakeup port ------------------------------------------
    logic        dispatch, dispatch_rs1_ready, dispatch_rs2_ready, dispatch_ready;
    logic [5:0]  dispatch_rs1, dispatch_rs2;
    logic [31:0] dispatch_payload;
    logic [0:0]       wake_valid;
    logic [0:0][5:0]  wake_tag;
    logic        issue_valid, issue_accept, flush;
    logic [31:0] issue_payload;
    logic [3:0]  count;

    issue_queue #(.DEPTH(DEPTH), .PHYS_REGS(64), .PAYLOAD_W(32), .NUM_WAKEUP(1))
    dut (.*);

    // ---- two wakeup ports, for the OR-versus-overwrite case ------------
    logic        d2_dispatch, d2_ready;
    logic [1:0]      d2_wake_valid;
    logic [1:0][5:0] d2_wake_tag;
    logic        d2_issue_valid, d2_issue_accept;
    logic [63:0] d2_issue_payload;
    logic [3:0]  d2_count;
    logic [5:0]  d2_rs1, d2_rs2;
    logic        d2_rs1_ready, d2_rs2_ready;
    logic [63:0] d2_payload;

    issue_queue #(.DEPTH(DEPTH), .PHYS_REGS(64), .PAYLOAD_W(64), .NUM_WAKEUP(2))
    dut2 (
        .clk(clk), .rst(rst),
        .dispatch(d2_dispatch),
        .dispatch_rs1(d2_rs1), .dispatch_rs1_ready(d2_rs1_ready),
        .dispatch_rs2(d2_rs2), .dispatch_rs2_ready(d2_rs2_ready),
        .dispatch_payload(d2_payload), .dispatch_ready(d2_ready),
        .wake_valid(d2_wake_valid), .wake_tag(d2_wake_tag),
        .issue_valid(d2_issue_valid), .issue_payload(d2_issue_payload),
        .issue_accept(d2_issue_accept),
        .flush(1'b0), .count(d2_count));

    logic [31:0] issued [$];

    task automatic tick();
        #1;
        if (issue_valid && issue_accept) begin
            issued.push_back(issue_payload);
        end
        @(negedge clk);
    endtask

    task automatic put(logic [5:0] r1, bit r1r, logic [5:0] r2, bit r2r,
                       logic [31:0] pl);
        dispatch           = 1'b1;
        dispatch_rs1       = r1;
        dispatch_rs1_ready = r1r;
        dispatch_rs2       = r2;
        dispatch_rs2_ready = r2r;
        dispatch_payload   = pl;
        tick();
        dispatch = 1'b0;
    endtask

    task automatic wake(logic [5:0] t);
        wake_valid = 1'b1;
        wake_tag[0] = t;
        tick();
        wake_valid = 1'b0;
    endtask

    task automatic reset_dut();
        rst = 1'b1;
        dispatch = 1'b0; dispatch_rs1 = '0; dispatch_rs2 = '0;
        dispatch_rs1_ready = 1'b0; dispatch_rs2_ready = 1'b0;
        dispatch_payload = '0;
        wake_valid = 1'b0; wake_tag[0] = '0;
        issue_accept = 1'b1; flush = 1'b0;
        d2_dispatch = 1'b0; d2_rs1 = '0; d2_rs2 = '0;
        d2_rs1_ready = 1'b0; d2_rs2_ready = 1'b0; d2_payload = '0;
        d2_wake_valid = 2'b00; d2_wake_tag[0] = '0; d2_wake_tag[1] = '0;
        d2_issue_accept = 1'b1;
        issued.delete();
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    initial begin
        reset_dut();

        // ---- reset ------------------------------------------------------
        expect_eq ("reset: empty",          {28'd0, count}, 32'd0);
        expect_bit("reset: accepts work",   dispatch_ready, 1'b1);
        expect_bit("reset: nothing to issue", issue_valid, 1'b0);

        // ---- a ready instruction issues; a waiting one does not -----------
        put(6'd0, 1'b1, 6'd0, 1'b1, 32'hAAAA);
        #1;
        expect_bit("both operands ready, so issuable", issue_valid, 1'b1);
        expect_eq ("issues the right payload", issue_payload, 32'hAAAA);
        tick();
        expect_eq("queue drained", {28'd0, count}, 32'd0);

        reset_dut();
        put(6'd40, 1'b0, 6'd0, 1'b1, 32'hBBBB);
        #1;
        expect_bit("waiting on rs1, not issuable", issue_valid, 1'b0);
        tick();
        expect_bit("still not issuable", issue_valid, 1'b0);

        // ---- ONE-CYCLE WAKEUP, both halves --------------------------------
        // The broadcast arrives. During that same cycle the entry must NOT be
        // issuable, because the value only reaches the register file when the
        // cycle ends. On the next cycle it must be.
        wake_valid  = 1'b1;
        wake_tag[0] = 6'd40;
        #1;
        expect_bit("not issuable during the broadcast cycle", issue_valid, 1'b0);
        @(negedge clk);
        wake_valid = 1'b0;
        #1;
        expect_bit("issuable the cycle after", issue_valid, 1'b1);
        expect_eq ("and it is the right one",  issue_payload, 32'hBBBB);
        tick();

        // A wakeup for a tag nobody wants changes nothing.
        reset_dut();
        put(6'd40, 1'b0, 6'd0, 1'b1, 32'hCCCC);
        wake(6'd41);
        #1;
        expect_bit("unrelated wakeup does not free it", issue_valid, 1'b0);
        wake(6'd40);
        #1;
        expect_bit("the right wakeup does", issue_valid, 1'b1);

        // ---- both operands must arrive -------------------------------------
        reset_dut();
        put(6'd40, 1'b0, 6'd41, 1'b0, 32'hDDDD);
        wake(6'd40);
        #1;
        expect_bit("one operand is not enough", issue_valid, 1'b0);
        wake(6'd41);
        #1;
        expect_bit("both operands is", issue_valid, 1'b1);

        // ---- an instruction dispatched on the cycle its operand arrives -----
        // The broadcast is gone by the next cycle, so an entry that missed it
        // at dispatch would wait forever.
        reset_dut();
        wake_valid  = 1'b1;
        wake_tag[0] = 6'd50;
        put(6'd50, 1'b0, 6'd0, 1'b1, 32'hEEEE);
        wake_valid = 1'b0;
        #1;
        expect_bit("dispatched into its own wakeup", issue_valid, 1'b1);
        expect_eq ("and it is the right one",        issue_payload, 32'hEEEE);

        // ---- AGE ORDER -------------------------------------------------------
        // Three instructions become ready in reverse order. They must issue
        // oldest first regardless, which is the property the collapse exists
        // for.
        reset_dut();
        issue_accept = 1'b0;                 // hold them all in the queue
        put(6'd40, 1'b0, 6'd0, 1'b1, 32'h1111);
        put(6'd41, 1'b0, 6'd0, 1'b1, 32'h2222);
        put(6'd42, 1'b0, 6'd0, 1'b1, 32'h3333);
        expect_eq("three queued", {28'd0, count}, 32'd3);

        wake(6'd42);                          // youngest ready first
        wake(6'd41);
        wake(6'd40);
        issue_accept = 1'b1;
        tick();
        tick();
        tick();
        expect_eq("all three issued", 32'(issued.size()), 32'd3);
        if (issued.size() == 3) begin
            expect_eq("oldest first",  issued[0], 32'h1111);
            expect_eq("then the next", issued[1], 32'h2222);
            expect_eq("then the last", issued[2], 32'h3333);
        end

        // ---- the collapse keeps order when the middle one leaves -------------
        reset_dut();
        issue_accept = 1'b0;
        put(6'd40, 1'b0, 6'd0, 1'b1, 32'h5555);   // waits
        put(6'd41, 1'b1, 6'd0, 1'b1, 32'h6666);   // ready now
        put(6'd42, 1'b1, 6'd0, 1'b1, 32'h7777);   // ready now
        issue_accept = 1'b1;
        tick();                                    // 6666 issues, entries shift
        tick();                                    // 7777 issues
        wake(6'd40);
        tick();                                    // 5555 issues last
        expect_eq("three issued after the collapse", 32'(issued.size()), 32'd3);
        if (issued.size() == 3) begin
            expect_eq("ready ones went first, in age order", issued[0], 32'h6666);
            expect_eq("second",                              issued[1], 32'h7777);
            expect_eq("the waiter came last",                issued[2], 32'h5555);
        end
        expect_eq("queue empty after the collapse", {28'd0, count}, 32'd0);

        // ---- a busy functional unit holds the instruction ---------------------
        reset_dut();
        issue_accept = 1'b0;
        put(6'd0, 1'b1, 6'd0, 1'b1, 32'h8888);
        tick();
        tick();
        expect_bit("still offering it",   issue_valid, 1'b1);
        expect_eq ("still the same one",  issue_payload, 32'h8888);
        expect_eq ("and still queued",    {28'd0, count}, 32'd1);
        issue_accept = 1'b1;
        tick();
        expect_eq("taken once accepted", {28'd0, count}, 32'd0);

        // ---- fills, and refuses more -------------------------------------------
        reset_dut();
        issue_accept = 1'b0;
        for (int i = 0; i < int'(DEPTH); i++) begin
            put(6'd40, 1'b0, 6'd0, 1'b1, 32'hF000 + 32'(i));
        end
        expect_eq ("full at DEPTH",        {28'd0, count}, DEPTH);
        expect_bit("full refuses dispatch", dispatch_ready, 1'b0);
        put(6'd40, 1'b0, 6'd0, 1'b1, 32'hDEAD);
        expect_eq("dispatch into a full queue is dropped", {28'd0, count}, DEPTH);

        // ---- flush empties it ---------------------------------------------------
        flush = 1'b1;
        tick();
        flush = 1'b0;
        #1;                       // dispatch_ready is combinational on flush
        expect_eq ("flush empties the queue",  {28'd0, count}, 32'd0);
        expect_bit("nothing left to issue",    issue_valid, 1'b0);
        expect_bit("accepting work again",     dispatch_ready, 1'b1);

        // ---- TWO WAKEUP PORTS ----------------------------------------------------
        // The case a single-port instance cannot reach. Both operands are woken
        // in the same cycle by DIFFERENT ports. A wakeup that assigns per port
        // instead of OR-ing lets the second port clear what the first set.
        reset_dut();
        d2_dispatch  = 1'b1;
        d2_rs1       = 6'd40;
        d2_rs1_ready = 1'b0;
        d2_rs2       = 6'd41;
        d2_rs2_ready = 1'b0;
        d2_payload   = 64'hDEAD_BEEF_1234_5678;
        @(negedge clk);
        d2_dispatch = 1'b0;
        #1;
        expect_bit("two-port: waiting on both", d2_issue_valid, 1'b0);

        d2_wake_valid  = 2'b11;
        d2_wake_tag[0] = 6'd40;
        d2_wake_tag[1] = 6'd41;
        @(negedge clk);
        d2_wake_valid = 2'b00;
        #1;
        expect_bit("two-port: both ports woke it", d2_issue_valid, 1'b1);
        // A wide payload has to survive intact, which is what the width
        // parameter is for. Checked half at a time because expect_eq is 32-bit.
        expect_eq("two-port: payload low half",  d2_issue_payload[31:0],  32'h1234_5678);
        expect_eq("two-port: payload high half", d2_issue_payload[63:32], 32'hDEAD_BEEF);

        // And the same again with the ports the other way round, so neither
        // ordering is the one that happens to work.
        reset_dut();
        d2_dispatch  = 1'b1;
        d2_rs1       = 6'd41;
        d2_rs1_ready = 1'b0;
        d2_rs2       = 6'd40;
        d2_rs2_ready = 1'b0;
        d2_payload   = 64'hABAB;
        @(negedge clk);
        d2_dispatch = 1'b0;

        d2_wake_valid  = 2'b11;
        d2_wake_tag[0] = 6'd40;
        d2_wake_tag[1] = 6'd41;
        @(negedge clk);
        d2_wake_valid = 2'b00;
        #1;
        expect_bit("two-port: order does not matter", d2_issue_valid, 1'b1);

        // One port matching and the other not must still wake the operand it
        // names -- this is the exact shape of the overwrite bug.
        reset_dut();
        d2_dispatch  = 1'b1;
        d2_rs1       = 6'd40;
        d2_rs1_ready = 1'b0;
        d2_rs2       = 6'd0;
        d2_rs2_ready = 1'b1;
        d2_payload   = 64'hCDCD;
        @(negedge clk);
        d2_dispatch = 1'b0;

        d2_wake_valid  = 2'b11;
        d2_wake_tag[0] = 6'd40;      // matches
        d2_wake_tag[1] = 6'd63;      // does not
        @(negedge clk);
        d2_wake_valid = 2'b00;
        #1;
        expect_bit("two-port: a non-matching port does not undo a match",
                   d2_issue_valid, 1'b1);

        report("issue_queue");
    end

endmodule
