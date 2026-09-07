// mdu: all eight RV32M instructions, both divider implementations.
//
// Two instances, because SEQUENTIAL is meant to change the cost and nothing
// else. The same vector table is driven through both and the results compared
// against the same expected value, so a divergence between the two cores shows
// up here rather than as a program that only fails on one of them.
//
// The vectors are written out by hand rather than generated. RV32M's hard part
// is not arithmetic, it is four cases the spec fixes by decree -- divide by
// zero, signed overflow, the direction truncation rounds, and which operand
// lends the remainder its sign -- and every one of them is a value you have to
// look up rather than derive. A generator built from the same misunderstanding
// as the DUT agrees with it. A table does not.

module tb_mdu
import rv32i_types::*;
;

    `include "tb_check.svh"

    logic clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // the two instances
    // ------------------------------------------------------------------
    logic [2:0]  c_f3;
    logic [31:0] c_a, c_b, c_result;
    logic        c_ready;

    mdu #(.SEQUENTIAL(1'b0)) dut_comb (
        .clk(clk), .rst(1'b0), .req(1'b1),
        .funct3(c_f3), .a(c_a), .b(c_b),
        .result(c_result), .ready(c_ready));

    logic        s_rst, s_req;
    logic [2:0]  s_f3;
    logic [31:0] s_a, s_b, s_result;
    logic        s_ready;

    mdu #(.SEQUENTIAL(1'b1)) dut_seq (
        .clk(clk), .rst(s_rst), .req(s_req),
        .funct3(s_f3), .a(s_a), .b(s_b),
        .result(s_result), .ready(s_ready));

    // ------------------------------------------------------------------
    // vector table
    // ------------------------------------------------------------------
    localparam int unsigned NVEC = 40;

    logic [2:0]  v_op   [NVEC];
    logic [31:0] v_a    [NVEC];
    logic [31:0] v_b    [NVEC];
    logic [31:0] v_want [NVEC];
    string       v_name [NVEC];
    int          nvec = 0;

    task automatic vec(string name, md_f3_t op,
                       logic [31:0] a, logic [31:0] b, logic [31:0] want);
        v_name[nvec] = name;
        v_op[nvec]   = op;
        v_a[nvec]    = a;
        v_b[nvec]    = b;
        v_want[nvec] = want;
        nvec         = nvec + 1;
    endtask

    task automatic build_vectors();
        // ---- multiply, ordinary ---------------------------------------
        vec("MUL 6*7",          md_f3_mul,    32'd6, 32'd7, 32'd42);
        vec("MUL negative",     md_f3_mul,    32'hffff_fffa, 32'd3, -32'd18);
        vec("MULH small stays high-zero",
                                md_f3_mulh,   32'd6, 32'd7, 32'd0);

        // The one operand pair that separates the three high multiplies. Same
        // bits in, three different answers out, which is the only way to catch
        // a unit that treats every high multiply as signed (or unsigned).
        vec("MULH   -1 x -1",   md_f3_mulh,   32'hffff_ffff, 32'hffff_ffff, 32'h0000_0000);
        vec("MULHSU -1 x 2^32-1",
                                md_f3_mulhsu, 32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff);
        vec("MULHU  2^32-1 squared",
                                md_f3_mulhu,  32'hffff_ffff, 32'hffff_ffff, 32'hffff_fffe);
        vec("MUL    2^32-1 squared, low",
                                md_f3_mul,    32'hffff_ffff, 32'hffff_ffff, 32'h0000_0001);

        // Same idea one step less extreme, where the sign of the answer rather
        // than its magnitude is what differs.
        vec("MULH   -1 x 2",    md_f3_mulh,   32'hffff_ffff, 32'd2, 32'hffff_ffff);
        vec("MULHSU -1 x 2",    md_f3_mulhsu, 32'hffff_ffff, 32'd2, 32'hffff_ffff);
        vec("MULHU  2^32-1 x 2",
                                md_f3_mulhu,  32'hffff_ffff, 32'd2, 32'h0000_0001);

        vec("MULH  min x min",  md_f3_mulh,   32'h8000_0000, 32'h8000_0000, 32'h4000_0000);
        vec("MUL   min x min",  md_f3_mul,    32'h8000_0000, 32'h8000_0000, 32'h0000_0000);
        vec("MULHU min x min",  md_f3_mulhu,  32'h8000_0000, 32'h8000_0000, 32'h4000_0000);

        // ---- divide, ordinary -----------------------------------------
        vec("DIVU  42/5",       md_f3_divu,   32'd42, 32'd5, 32'd8);
        vec("REMU  42%5",       md_f3_remu,   32'd42, 32'd5, 32'd2);
        vec("DIV   42/5",       md_f3_div,    32'd42, 32'd5, 32'd8);
        vec("REM   42%5",       md_f3_rem,    32'd42, 32'd5, 32'd2);
        vec("DIVU  exact",      md_f3_divu,   32'd100, 32'd10, 32'd10);
        vec("REMU  exact",      md_f3_remu,   32'd100, 32'd10, 32'd0);
        vec("DIVU  by 1",       md_f3_divu,   32'hdead_beef, 32'd1, 32'hdead_beef);
        vec("DIVU  divisor bigger",
                                md_f3_divu,   32'd3, 32'd10, 32'd0);
        vec("REMU  divisor bigger",
                                md_f3_remu,   32'd3, 32'd10, 32'd3);

        // ---- truncation direction, and the remainder's sign -------------
        // -7/2 is -3, not -4: RISC-V truncates toward zero. The remainder then
        // takes the DIVIDEND's sign to keep a == (a/b)*b + a%b.
        vec("DIV  -7/2 truncates to zero",
                                md_f3_div,    -32'd7, 32'd2, -32'd3);
        vec("REM  -7%2 takes dividend sign",
                                md_f3_rem,    -32'd7, 32'd2, -32'd1);
        vec("DIV   7/-2",       md_f3_div,    32'd7, -32'd2, -32'd3);
        vec("REM   7%-2 stays positive",
                                md_f3_rem,    32'd7, -32'd2, 32'd1);
        vec("DIV  -7/-2",       md_f3_div,    -32'd7, -32'd2, 32'd3);
        vec("REM  -7%-2",       md_f3_rem,    -32'd7, -32'd2, -32'd1);

        // The same bits read two ways: as -1 the quotient is 0, as 2^32-1 it
        // is 0x7fffffff. Nothing else distinguishes DIV from DIVU as cleanly.
        vec("DIV  -1/2 is zero",
                                md_f3_div,    32'hffff_ffff, 32'd2, 32'd0);
        vec("DIVU 2^32-1 / 2",  md_f3_divu,   32'hffff_ffff, 32'd2, 32'h7fff_ffff);
        vec("REM  -1%2",        md_f3_rem,    32'hffff_ffff, 32'd2, 32'hffff_ffff);
        vec("REMU 2^32-1 % 2",  md_f3_remu,   32'hffff_ffff, 32'd2, 32'd1);

        // ---- the two decreed cases --------------------------------------
        // Divide by zero does not trap, because RV32M has no way to. The
        // quotient is all ones and the remainder is the dividend, both
        // signednesses alike.
        vec("DIV  by zero is -1",
                                md_f3_div,    32'd42, 32'd0, 32'hffff_ffff);
        vec("DIVU by zero is all ones",
                                md_f3_divu,   32'd42, 32'd0, 32'hffff_ffff);
        vec("REM  by zero is the dividend",
                                md_f3_rem,    32'd42, 32'd0, 32'd42);
        vec("REMU by zero is the dividend",
                                md_f3_remu,   32'd42, 32'd0, 32'd42);
        vec("DIV  0/0",         md_f3_div,    32'd0, 32'd0, 32'hffff_ffff);

        // -2^31 / -1 overflows a signed 32-bit result. The answer is the
        // dividend back, and again no trap.
        vec("DIV  min/-1 overflows to min",
                                md_f3_div,    32'h8000_0000, 32'hffff_ffff, 32'h8000_0000);
        vec("REM  min%-1 is zero",
                                md_f3_rem,    32'h8000_0000, 32'hffff_ffff, 32'd0);
        // Unsigned reads the same bits as 2^31 and 2^32-1, where nothing
        // overflows and the ordinary answer applies.
        vec("DIVU same bits does not overflow",
                                md_f3_divu,   32'h8000_0000, 32'hffff_ffff, 32'd0);
        vec("REMU same bits does not overflow",
                                md_f3_remu,   32'h8000_0000, 32'hffff_ffff, 32'h8000_0000);
    endtask

    // ------------------------------------------------------------------
    // drivers
    // ------------------------------------------------------------------
    task automatic run_comb(logic [2:0] op, logic [31:0] a, logic [31:0] b,
                            output logic [31:0] res);
        c_f3 = op;
        c_a  = a;
        c_b  = b;
        #1;
        res = c_result;
    endtask

    // Drives the handshake and returns how many cycles the instruction would
    // occupy EX -- the number the pipeline pays, not an internal iteration
    // count.
    task automatic run_seq(logic [2:0] op, logic [31:0] a, logic [31:0] b,
                           output logic [31:0] res, output int cycles);
        @(negedge clk);
        s_f3  = op;
        s_a   = a;
        s_b   = b;
        s_req = 1'b1;
        #1;
        cycles = 1;
        while (!s_ready) begin
            @(negedge clk);
            #1;
            cycles = cycles + 1;
        end
        res   = s_result;
        s_req = 1'b0;
        @(negedge clk);
    endtask

    // SystemVerilog's own signed divide truncates toward zero exactly as
    // RISC-V specifies, so for the ordinary cases it is a genuinely separate
    // implementation of what the magnitude-and-fixup path computes. It says
    // nothing about the two decreed cases, which is why they are excluded here
    // and written out by hand above.
    function automatic logic [31:0] ref_div(md_f3_t op,
                                            logic [31:0] a, logic [31:0] b);
        logic signed [31:0] sa, sb;
        sa = signed'(a);
        sb = signed'(b);
        unique case (op)
            md_f3_div:  ref_div = unsigned'(sa / sb);
            md_f3_divu: ref_div = a / b;
            md_f3_rem:  ref_div = unsigned'(sa % sb);
            md_f3_remu: ref_div = a % b;
            default:    ref_div = 'x;
        endcase
    endfunction

    // ------------------------------------------------------------------
    logic [31:0] got_c, got_s, ra, rb;
    int          cyc;

    initial begin
        s_rst = 1'b1;
        s_req = 1'b0;
        s_f3  = md_f3_mul;
        s_a   = '0;
        s_b   = '0;
        repeat (2) @(negedge clk);
        s_rst = 1'b0;
        @(negedge clk);

        build_vectors();

        // ---- the table, through the combinational unit -------------------
        for (int i = 0; i < nvec; i++) begin
            run_comb(v_op[i], v_a[i], v_b[i], got_c);
            expect_eq({"comb ", v_name[i]}, got_c, v_want[i]);
        end

        // ---- the same table, through the sequential unit ------------------
        // The parameter is supposed to buy cycles, not change answers.
        for (int i = 0; i < nvec; i++) begin
            run_seq(v_op[i], v_a[i], v_b[i], got_s, cyc);
            expect_eq({"seq  ", v_name[i]}, got_s, v_want[i]);
        end

        // ---- what each family costs --------------------------------------
        // A multiply is combinational in both builds, so it leaves EX on the
        // cycle it arrives and the pipeline never stalls for it.
        run_seq(md_f3_mul,  32'd6, 32'd7, got_s, cyc);
        expect_eq("multiply occupies EX for 1 cycle", cyc, 32'd1);
        run_seq(md_f3_mulh, 32'd6, 32'd7, got_s, cyc);
        expect_eq("mulh occupies EX for 1 cycle",     cyc, 32'd1);

        // A divide is 32 iterations plus a cycle to load and a cycle to
        // present. Asserting the exact number is the point: a divider that
        // answers early is wrong, and one that answers late is invisible in
        // every test that only reads registers.
        run_seq(md_f3_divu, 32'd42, 32'd5, got_s, cyc);
        expect_eq("divide occupies EX for 34 cycles", cyc, 32'd34);
        run_seq(md_f3_rem,  -32'd7, 32'd2, got_s, cyc);
        expect_eq("remainder costs the same",         cyc, 32'd34);

        // Divide by zero still runs the machine rather than short-circuiting.
        // Worth pinning: a special case that also changed the timing would be
        // a second, undocumented behaviour.
        run_seq(md_f3_divu, 32'd42, 32'd0, got_s, cyc);
        expect_eq("divide by zero costs the same",    cyc, 32'd34);

        // ---- back to back, which is where a stuck FSM shows up ------------
        // The unit must return to idle between requests. If it latched `done`
        // it would hand the second divide the first one's answer instantly.
        run_seq(md_f3_divu, 32'd100, 32'd10, got_s, cyc);
        expect_eq("first of a pair",       got_s, 32'd10);
        run_seq(md_f3_divu, 32'd90,  32'd9,  got_s, cyc);
        expect_eq("second of a pair",      got_s, 32'd10);
        expect_eq("second pays full cost", cyc,   32'd34);

        // ---- random cross-check against SystemVerilog's own divide ---------
        for (int i = 0; i < 60; i++) begin
            ra = $urandom();
            rb = $urandom();
            if (rb == '0) begin
                rb = 32'd1;
            end
            // Excluded above: the one signed pair with no truncating answer.
            if (!(ra == 32'h8000_0000 && rb == 32'hffff_ffff)) begin
                run_comb(md_f3_div,  ra, rb, got_c);
                expect_eq("random DIV",  got_c, ref_div(md_f3_div,  ra, rb));
                run_comb(md_f3_divu, ra, rb, got_c);
                expect_eq("random DIVU", got_c, ref_div(md_f3_divu, ra, rb));
                run_comb(md_f3_rem,  ra, rb, got_c);
                expect_eq("random REM",  got_c, ref_div(md_f3_rem,  ra, rb));
                run_comb(md_f3_remu, ra, rb, got_c);
                expect_eq("random REMU", got_c, ref_div(md_f3_remu, ra, rb));
            end
        end

        // ---- and the identity that ties quotient to remainder --------------
        // a == (a/b)*b + a%b, for both signednesses. Catches a sign fixup that
        // is self-consistently wrong in both halves.
        for (int i = 0; i < 20; i++) begin
            logic [31:0] q, r;
            ra = $urandom();
            rb = $urandom();
            if (rb == '0) begin
                rb = 32'd1;
            end
            if (!(ra == 32'h8000_0000 && rb == 32'hffff_ffff)) begin
                run_comb(md_f3_div, ra, rb, q);
                run_comb(md_f3_rem, ra, rb, r);
                expect_eq("signed q*b + r == a",   (q * rb) + r, ra);
                run_comb(md_f3_divu, ra, rb, q);
                run_comb(md_f3_remu, ra, rb, r);
                expect_eq("unsigned q*b + r == a", (q * rb) + r, ra);
            end
        end

        report("mdu");
    end

endmodule
