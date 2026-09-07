// regfile: x0 behaviour and the WRITE_FIRST bypass.
//
// Two instances, because the parameter is the whole point: the pipelined core
// needs the WB-to-ID bypass and the single-cycle core must not have it, where
// the read and write in a cycle belong to the same instruction and a bypass
// would be a combinational loop rather than forwarding.

module tb_regfile
import rv32i_types::*;
;

    `include "tb_check.svh"

    logic        clk = 1'b0;
    logic        rst;
    logic        regf_we;
    logic [31:0] rd_v;
    logic [4:0]  rs1_s, rs2_s, rd_s;

    logic [31:0] wf_rs1_v, wf_rs2_v;    // WRITE_FIRST = 1
    logic [31:0] nb_rs1_v, nb_rs2_v;    // WRITE_FIRST = 0

    always #5 clk = ~clk;

    regfile #(.WRITE_FIRST(1'b1)) dut_wf (
        .clk(clk), .rst(rst), .regf_we(regf_we), .rd_v(rd_v),
        .rs1_s(rs1_s), .rs2_s(rs2_s), .rd_s(rd_s),
        .rs1_v(wf_rs1_v), .rs2_v(wf_rs2_v));

    regfile #(.WRITE_FIRST(1'b0)) dut_nb (
        .clk(clk), .rst(rst), .regf_we(regf_we), .rd_v(rd_v),
        .rs1_s(rs1_s), .rs2_s(rs2_s), .rd_s(rd_s),
        .rs1_v(nb_rs1_v), .rs2_v(nb_rs2_v));

    task automatic write(logic [4:0] r, logic [31:0] v);
        @(negedge clk);
        regf_we = 1'b1;
        rd_s    = r;
        rd_v    = v;
        @(negedge clk);
        regf_we = 1'b0;
    endtask

    initial begin
        rst = 1'b1; regf_we = 1'b0; rd_s = '0; rd_v = '0;
        rs1_s = '0; rs2_s = '0;
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;

        // ---- basic write then read ---------------------------------------
        write(5'd1, 32'hdead_beef);
        rs1_s = 5'd1; #1;
        expect_eq("write then read", wf_rs1_v, 32'hdead_beef);

        write(5'd2, 32'h1234_5678);
        rs2_s = 5'd2; #1;
        expect_eq("second port reads", wf_rs2_v, 32'h1234_5678);
        expect_eq("first port unchanged", wf_rs1_v, 32'hdead_beef);

        // ---- x0 stays zero no matter what --------------------------------
        write(5'd0, 32'hffff_ffff);
        rs1_s = 5'd0; #1;
        expect_eq("x0 reads zero", wf_rs1_v, 32'd0);

        // ---- reset clears everything -------------------------------------
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
        rs1_s = 5'd1; #1;
        expect_eq("reset clears x1", wf_rs1_v, 32'd0);

        // ---- the bypass, which is the reason the parameter exists ---------
        // Drive a write to x5 while reading x5 in the same cycle. WRITE_FIRST
        // must return the value being written; the plain version must return
        // what is still stored.
        write(5'd5, 32'h0000_1111);

        @(negedge clk);
        regf_we = 1'b1;
        rd_s    = 5'd5;
        rd_v    = 32'h0000_2222;
        rs1_s   = 5'd5;
        #1;
        expect_eq("WRITE_FIRST bypasses",   wf_rs1_v, 32'h0000_2222);
        expect_eq("no bypass reads stored", nb_rs1_v, 32'h0000_1111);

        @(negedge clk);
        regf_we = 1'b0;
        #1;
        expect_eq("both settle after write", wf_rs1_v, 32'h0000_2222);
        expect_eq("no-bypass caught up",     nb_rs1_v, 32'h0000_2222);

        // A write to x0 must not be bypassed either: x0 reads zero always.
        @(negedge clk);
        regf_we = 1'b1;
        rd_s    = 5'd0;
        rd_v    = 32'hffff_ffff;
        rs1_s   = 5'd0;
        #1;
        expect_eq("x0 not bypassed", wf_rs1_v, 32'd0);

        report("regfile");
    end

endmodule
