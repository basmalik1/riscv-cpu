// prf: the physical register file and its ready bits.
//
// Two things here are worth more than the storage checks.
//
// The ready bit, which is the entire dependency mechanism. Rename clears it on
// allocate, writeback sets it, and the issue queue does nothing but wait for
// both of an instruction's sources to read ready. A ready bit that is set when
// it should not be issues an instruction against a stale value; one that is
// clear when it should be set deadlocks the machine. Neither shows up as a
// wrong number in this module -- only as the wrong ANSWER to "may this
// instruction go", which is why it is checked directly here.
//
// Tag 0, which rat.sv permanently maps architectural x0 to. It has to read as
// zero and as ready no matter what is done to it.

module tb_prf;

    `include "tb_check.svh"

    localparam int unsigned PHYS = 64;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    logic [5:0]  rs1_tag, rs2_tag, alloc_tag, wb_tag;
    logic [31:0] rs1_value, rs2_value, wb_value;
    logic        rs1_ready, rs2_ready, alloc, wb;

    prf #(.PHYS_REGS(PHYS)) dut (.*);

    // Independent model of what the file should hold.
    logic [31:0] m_data  [PHYS];
    bit          m_ready [PHYS];

    task automatic do_alloc(logic [5:0] t);
        alloc     = 1'b1;
        alloc_tag = t;
        @(negedge clk);
        alloc = 1'b0;
        if (t != 6'd0) begin
            m_ready[t] = 1'b0;
        end
    endtask

    task automatic do_wb(logic [5:0] t, logic [31:0] v);
        wb       = 1'b1;
        wb_tag   = t;
        wb_value = v;
        @(negedge clk);
        wb = 1'b0;
        if (t != 6'd0) begin
            m_data[t]  = v;
            m_ready[t] = 1'b1;
        end
    endtask

    task automatic reset_dut();
        rst = 1'b1; alloc = 1'b0; wb = 1'b0;
        rs1_tag = '0; rs2_tag = '0; alloc_tag = '0; wb_tag = '0; wb_value = '0;
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (int i = 0; i < int'(PHYS); i++) begin
            m_data[i]  = 32'd0;
            m_ready[i] = 1'b1;
        end
        @(negedge clk);
    endtask

    int a, b;

    initial begin
        reset_dut();

        // ---- reset: everything zero and everything ready --------------------
        for (int i = 0; i < int'(PHYS); i++) begin
            rs1_tag = 6'(i);
            #1;
            expect_eq ("reset: value is zero", rs1_value, 32'd0);
            expect_bit("reset: ready is set",  rs1_ready, 1'b1);
        end

        // ---- a value written is a value read --------------------------------
        do_wb(6'd40, 32'hdead_beef);
        rs1_tag = 6'd40; #1;
        expect_eq ("write then read",   rs1_value, 32'hdead_beef);
        expect_bit("writeback is ready", rs1_ready, 1'b1);

        rs2_tag = 6'd41; #1;
        expect_eq("neighbour untouched", rs2_value, 32'd0);

        // ---- both read ports are independent ---------------------------------
        do_wb(6'd41, 32'h1234_5678);
        rs1_tag = 6'd40; rs2_tag = 6'd41; #1;
        expect_eq("port 1", rs1_value, 32'hdead_beef);
        expect_eq("port 2", rs2_value, 32'h1234_5678);

        // ---- the ready bit, which is the dependency mechanism ----------------
        // Allocate clears it: the register now belongs to an instruction that
        // has not executed, so what is in it is stale and nothing may issue
        // against it.
        do_alloc(6'd40);
        rs1_tag = 6'd40; #1;
        expect_bit("allocate clears ready", rs1_ready, 1'b0);
        expect_eq ("stale value still readable while not ready",
                   rs1_value, 32'hdead_beef);

        // Writeback sets it again, with the new value.
        do_wb(6'd40, 32'h0bad_c0de);
        rs1_tag = 6'd40; #1;
        expect_bit("writeback sets ready", rs1_ready, 1'b1);
        expect_eq ("writeback delivers the value", rs1_value, 32'h0bad_c0de);

        // Allocating one register must not disturb another's readiness.
        do_alloc(6'd50);
        rs1_tag = 6'd50; rs2_tag = 6'd40; #1;
        expect_bit("allocated one is not ready", rs1_ready, 1'b0);
        expect_bit("its neighbour still is",     rs2_ready, 1'b1);

        // ---- no read bypass, and the cycle after --------------------------
        // An instruction reading a tag on the cycle it is written back sees the
        // OLD value. That is correct here and is the reason the issue queue
        // issues the cycle AFTER a broadcast rather than during it -- by then
        // the write has landed and an ordinary read returns it.
        do_wb(6'd42, 32'haaaa_aaaa);
        rs1_tag  = 6'd42;
        wb       = 1'b1;
        wb_tag   = 6'd42;
        wb_value = 32'hbbbb_bbbb;
        #1;
        expect_eq ("no bypass: read sees the old value", rs1_value, 32'haaaa_aaaa);
        @(negedge clk);
        wb = 1'b0;
        m_data[42] = 32'hbbbb_bbbb;
        #1;
        expect_eq("the cycle after, the new value is there", rs1_value, 32'hbbbb_bbbb);

        // ---- allocate and writeback together, on different tags -------------
        // The steady state: rename allocating for one instruction while a
        // functional unit retires another.
        do_wb(6'd44, 32'd7);
        alloc     = 1'b1;
        alloc_tag = 6'd45;
        wb        = 1'b1;
        wb_tag    = 6'd44;
        wb_value  = 32'd99;
        @(negedge clk);
        alloc = 1'b0;
        wb    = 1'b0;
        m_ready[45] = 1'b0;
        m_data[44]  = 32'd99;
        rs1_tag = 6'd45; rs2_tag = 6'd44; #1;
        expect_bit("same cycle: the allocated one is not ready", rs1_ready, 1'b0);
        expect_bit("same cycle: the written one is ready",       rs2_ready, 1'b1);
        expect_eq ("same cycle: the written value landed",       rs2_value, 32'd99);

        // ---- tag 0 survives everything --------------------------------------
        // rat.sv maps x0 here permanently. In a correct machine nothing ever
        // allocates or writes it, so these are checks that the guard holds
        // rather than checks of something that happens.
        do_wb(6'd0, 32'hffff_ffff);
        rs1_tag = 6'd0; #1;
        expect_eq ("tag 0 reads zero after a write", rs1_value, 32'd0);
        expect_bit("tag 0 stays ready after a write", rs1_ready, 1'b1);

        do_alloc(6'd0);
        rs1_tag = 6'd0; #1;
        expect_eq ("tag 0 reads zero after an allocate",  rs1_value, 32'd0);
        expect_bit("tag 0 stays ready after an allocate", rs1_ready, 1'b1);

        // And neither disturbed anything else.
        rs1_tag = 6'd44; #1;
        expect_eq("tag 0 traffic left tag 44 alone", rs1_value, 32'd99);

        // ---- reset clears a dirty file ---------------------------------------
        reset_dut();
        rs1_tag = 6'd40; rs2_tag = 6'd50; #1;
        expect_eq ("reset: value cleared", rs1_value, 32'd0);
        expect_bit("reset: ready restored", rs2_ready, 1'b1);

        // ---- a long random run against the model ------------------------------
        for (int i = 0; i < 3000; i++) begin
            a = $urandom_range(1, int'(PHYS) - 1);
            b = $urandom_range(1, int'(PHYS) - 1);

            alloc     = ($urandom_range(0, 2) == 0);
            alloc_tag = 6'(a);
            wb        = ($urandom_range(0, 1) == 0);
            wb_tag    = 6'(b);
            wb_value  = $urandom();

            rs1_tag = 6'($urandom_range(0, int'(PHYS) - 1));
            rs2_tag = 6'($urandom_range(0, int'(PHYS) - 1));
            #1;

            expect_eq ("random: rs1 value", rs1_value,
                       (rs1_tag == 6'd0) ? 32'd0 : m_data[rs1_tag]);
            expect_bit("random: rs1 ready", rs1_ready,
                       (rs1_tag == 6'd0) ? 1'b1 : m_ready[rs1_tag]);
            expect_eq ("random: rs2 value", rs2_value,
                       (rs2_tag == 6'd0) ? 32'd0 : m_data[rs2_tag]);
            expect_bit("random: rs2 ready", rs2_ready,
                       (rs2_tag == 6'd0) ? 1'b1 : m_ready[rs2_tag]);

            @(negedge clk);
            // Model the same ordering the module uses: allocate first, then
            // writeback, so a collision on one tag ends up ready.
            if (alloc) begin
                m_ready[alloc_tag] = 1'b0;
            end
            if (wb) begin
                m_data[wb_tag]  = wb_value;
                m_ready[wb_tag] = 1'b1;
            end
            alloc = 1'b0;
            wb    = 1'b0;
        end

        // Whatever the random run left must match entry for entry.
        for (int i = 0; i < int'(PHYS); i++) begin
            rs1_tag = 6'(i);
            #1;
            expect_eq ("final value matches the model", rs1_value,
                       (i == 0) ? 32'd0 : m_data[i]);
            expect_bit("final ready matches the model", rs1_ready,
                       (i == 0) ? 1'b1 : m_ready[i]);
        end

        report("prf");
    end

endmodule
