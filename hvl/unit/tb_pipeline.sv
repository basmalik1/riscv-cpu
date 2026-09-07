// Cycle-level harness for the assembled pipeline.
//
// Sits between the two things that already exist. The per-stage testbenches
// check one module against its inputs; the programs in testcode/ check whether
// a whole computation comes out right. Neither can say "this load-use cost
// exactly one extra cycle" or "the two instructions behind that branch did not
// write a register", which is where pipeline bugs actually live.
//
// So: assemble instructions from small encoder functions, run a fixed number
// of cycles, and assert on cycle counts, retirement counts and register
// contents. Counting cycles is what makes stalls and squashes observable --
// a wrong answer shows up in the registers, but a spurious stall only ever
// shows up in the timing.

module tb_pipeline
import rv32i_types::*;
import pipelined_types::*;
;

    `include "tb_check.svh"

    localparam int unsigned WORDS = 256;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_rmask, dmem_wmask;
    logic        halt, commit;

    // RESET_PC is 0 here so a word address is just an array index.
    cpu #(.RESET_PC(32'h0)) dut (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_rmask(dmem_rmask), .dmem_wmask(dmem_wmask),
        .dmem_rdata(dmem_rdata),
        .halt(halt), .commit(commit));

    // Registered reads, matching what the core is written against.
    logic [31:0] mem [WORDS];

    // Word index, wrapped. The explicit widening matters: addr[31:2] is 30 bits
    // and the modulo wants 32, which Verilator flags rather than silently
    // extending.
    function automatic int unsigned widx(logic [31:0] addr);
        widx = 32'(addr[31:2]) % WORDS;
    endfunction

    always_ff @(posedge clk) begin
        imem_rdata <= mem[widx(imem_addr)];
        dmem_rdata <= mem[widx(dmem_addr)];
        for (int i = 0; i < 4; i++) begin
            if (dmem_wmask[i]) begin
                mem[widx(dmem_addr)][8*i +: 8] <= dmem_wdata[8*i +: 8];
            end
        end
    end

    int cycles;
    int retired;

    always_ff @(posedge clk) begin
        if (rst) begin
            cycles  <= 0;
            retired <= 0;
        end else begin
            cycles <= cycles + 1;
            if (commit) begin
                retired <= retired + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // instruction encoders -- raw hex is unreadable and easy to get wrong
    // ------------------------------------------------------------------
    function automatic logic [31:0] i_addi(int rd, int rs1, int imm);
        i_addi = {imm[11:0], rs1[4:0], 3'b000, rd[4:0], 7'b0010011};
    endfunction

    function automatic logic [31:0] i_add(int rd, int rs1, int rs2);
        i_add = {7'b0000000, rs2[4:0], rs1[4:0], 3'b000, rd[4:0], 7'b0110011};
    endfunction

    function automatic logic [31:0] i_lw(int rd, int rs1, int imm);
        i_lw = {imm[11:0], rs1[4:0], 3'b010, rd[4:0], 7'b0000011};
    endfunction

    function automatic logic [31:0] i_sw(int rs1, int rs2, int imm);
        i_sw = {imm[11:5], rs2[4:0], rs1[4:0], 3'b010, imm[4:0], 7'b0100011};
    endfunction

    function automatic logic [31:0] i_beq(int rs1, int rs2, int imm);
        i_beq = {imm[12], imm[10:5], rs2[4:0], rs1[4:0], 3'b000,
                 imm[4:1], imm[11], 7'b1100011};
    endfunction

    function automatic logic [31:0] i_nop();
        i_nop = i_addi(0, 0, 0);
    endfunction

    // ------------------------------------------------------------------
    // harness control
    // ------------------------------------------------------------------
    task automatic clear_mem();
        for (int i = 0; i < int'(WORDS); i++) begin
            mem[i] = i_nop();       // nops, so a runaway PC does nothing odd
        end
    endtask

    task automatic reset_dut();
        rst = 1'b1;
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    task automatic run(int n);
        repeat (n) @(negedge clk);
    endtask

    // The register file is inside the core; reaching in is the point of a
    // white-box harness.
    function automatic logic [31:0] reg_of(int n);
        reg_of = dut.regfile_inst.data[n];
    endfunction

    // Retirements in a hazard-free window, measured rather than assumed.
    int base_retired;

    initial begin
        // ---- a straight run retires one instruction per cycle -----------
        // Five independent addi, nothing to stall on. Retirement lags fetch by
        // the depth of the pipeline, so what is checked is the RATE.
        clear_mem();
        mem[0] = i_addi(1, 0, 1);
        mem[1] = i_addi(2, 0, 2);
        mem[2] = i_addi(3, 0, 3);
        mem[3] = i_addi(4, 0, 4);
        mem[4] = i_addi(5, 0, 5);
        reset_dut();
        run(20);
        expect_eq("straight: x1", reg_of(1), 32'd1);
        expect_eq("straight: x5", reg_of(5), 32'd5);
        base_retired = retired;             // the hazard-free reference
        $display("  (baseline: %0d retired in 20 cycles)", base_retired);

        // ---- forwarding at distance 1 and 2 -----------------------------
        clear_mem();
        mem[0] = i_addi(1, 0, 10);
        mem[1] = i_addi(2, 1, 1);       // needs x1 from MEM
        mem[2] = i_addi(3, 1, 2);       // needs x1 from WB
        mem[3] = i_add (4, 2, 3);       // both operands forwarded
        reset_dut();
        run(20);
        expect_eq("fwd distance 1", reg_of(2), 32'd11);
        expect_eq("fwd distance 2", reg_of(3), 32'd12);
        expect_eq("fwd both operands", reg_of(4), 32'd23);

        // ---- a load-use costs exactly one cycle -------------------------
        // Same four instructions twice, differing only in whether the consumer
        // sits immediately behind the load. The cycle difference isolates the
        // stall, which no register value can reveal.
        clear_mem();
        mem[0] = i_addi(1, 0, 40);      // address 40 -> word 10
        mem[1] = i_sw  (1, 1, 0);       // mem[10] = 40
        mem[2] = i_lw  (2, 1, 0);
        mem[3] = i_addi(3, 2, 1);       // load-use, distance 1
        reset_dut();
        run(20);
        expect_eq("load-use: value", reg_of(3), 32'd41);
        // The whole point: exactly one cycle, no more and no fewer.
        expect_eq("load-use costs exactly 1", retired, base_retired - 1);

        clear_mem();
        mem[0] = i_addi(1, 0, 40);
        mem[1] = i_sw  (1, 1, 0);
        mem[2] = i_lw  (2, 1, 0);
        mem[3] = i_nop();               // consumer moved one further away
        mem[4] = i_addi(3, 2, 1);
        reset_dut();
        run(20);
        expect_eq("no load-use: value", reg_of(3), 32'd41);
        expect_eq("distance 2 costs nothing", retired, base_retired);

        // ---- a taken branch costs exactly two -----------------------------
        clear_mem();
        mem[0] = i_addi(1, 0, 5);
        mem[1] = i_addi(2, 0, 5);
        mem[2] = i_beq (1, 2, 12);      // taken, to mem[5]
        mem[3] = i_addi(9, 0, 99);      // squashed
        mem[4] = i_addi(10, 0, 99);     // squashed
        mem[5] = i_addi(3, 0, 7);
        reset_dut();
        run(20);
        expect_eq("branch: target ran",     reg_of(3),  32'd7);
        // The two instructions behind a taken branch must leave no trace.
        expect_eq("branch: shadow 1 killed", reg_of(9),  32'd0);
        expect_eq("branch: shadow 2 killed", reg_of(10), 32'd0);
        expect_eq("taken branch costs exactly 2", retired, base_retired - 2);

        // ---- a not-taken branch costs nothing ----------------------------
        clear_mem();
        mem[0] = i_addi(1, 0, 5);
        mem[1] = i_addi(2, 0, 6);
        mem[2] = i_beq (1, 2, 12);      // not taken
        mem[3] = i_addi(9, 0, 42);      // must run
        reset_dut();
        run(20);
        expect_eq("not taken: fallthrough ran", reg_of(9), 32'd42);
        expect_eq("not taken costs nothing",    retired,   base_retired);

        // ---- a branch resolved from a forwarded operand ------------------
        // The comparison must use the forwarded value, not the stale one read
        // in ID, or the branch resolves on data one instruction out of date.
        clear_mem();
        mem[0] = i_addi(1, 0, 7);
        mem[1] = i_addi(2, 0, 7);       // still in flight when the branch runs
        mem[2] = i_beq (1, 2, 8);       // taken only if x2 is forwarded
        mem[3] = i_addi(9, 0, 99);      // squashed if taken
        mem[4] = i_addi(3, 0, 1);
        reset_dut();
        run(20);
        expect_eq("branch on forwarded op taken", reg_of(3), 32'd1);
        expect_eq("branch on forwarded op squash", reg_of(9), 32'd0);

        // ---- x0 stays zero through the pipeline --------------------------
        clear_mem();
        mem[0] = i_addi(0, 0, 99);      // writes x0, must be discarded
        mem[1] = i_addi(1, 0, 0);       // reads x0 right behind it
        reset_dut();
        run(20);
        expect_eq("x0 not written",   reg_of(0), 32'd0);
        expect_eq("x0 not forwarded", reg_of(1), 32'd0);

        report("pipeline");
    end

endmodule
