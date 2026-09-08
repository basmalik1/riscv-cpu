// fetch: one instruction per cycle, and none lost or repeated across a stall.
//
// The property worth the effort is the one the pipelined core got wrong first
// time. Holding the program counter does not hold the instruction when the
// memory read is synchronous: the address for the next fetch has already gone
// to memory by the time dispatch refuses the current one, so without a replay
// the machine silently drops one instruction per stall.
//
// The check for that is a scoreboard rather than a directed case. Run a long
// sequence with stalls appearing at random, collect everything fetch offered,
// and require the result to be exactly the program in order -- no gaps, no
// repeats. A dropped instruction and a duplicated one both show, and neither
// would show in a test that only asked whether the pc advanced.

module tb_fetch;

    `include "tb_check.svh"

    localparam bit [31:0] BASE = 32'h8000_0000;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    logic        stall, flush;
    logic [31:0] flush_pc;
    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] inst, pc;
    logic        valid;

    fetch #(.RESET_PC(BASE)) dut (.*);

    // Synchronous read, which is the whole reason this module is difficult.
    // Word i holds 0xC0DE0000 + i, so an instruction says which address it
    // came from.
    //
    // Deliberately larger than the longest run below. At 256 words this
    // wrapped part way through the random test and reported a divergence that
    // was the model's, not the design's -- the fetched pc was right the whole
    // time and only the expected instruction had run off the end.
    logic [31:0] mem [1024];
    always_ff @(posedge clk) begin
        imem_rdata <= mem[imem_addr[11:2]];
    end

    // Everything fetch offered, in order.
    logic [31:0] got_inst [$];
    logic [31:0] got_pc   [$];

    // Take whatever is on offer this cycle, then advance.
    task automatic step(bit do_stall);
        stall = do_stall;
        #1;
        if (valid && !do_stall) begin
            got_inst.push_back(inst);
            got_pc.push_back(pc);
        end
        @(negedge clk);
    endtask

    task automatic reset_dut();
        rst = 1'b1; stall = 1'b0; flush = 1'b0; flush_pc = '0;
        for (int i = 0; i < 1024; i++) begin
            mem[i] = 32'hC0DE_0000 + 32'(i);
        end
        got_inst.delete();
        got_pc.delete();
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    int n;
    bit ok;

    initial begin
        reset_dut();

        // ---- instructions arrive in order, with their own addresses --------
        for (int i = 0; i < 8; i++) begin
            step(1'b0);
        end
        expect_eq("eight offered", 32'(got_inst.size()), 32'd8);
        ok = 1'b1;
        for (int i = 0; i < got_inst.size(); i++) begin
            if (got_inst[i] !== 32'hC0DE_0000 + 32'(i)) ok = 1'b0;
            if (got_pc[i]   !== BASE + 32'(i) * 4)      ok = 1'b0;
        end
        expect_bit("in order, each with its own pc", ok, 1'b1);

        // ---- a stall repeats the SAME instruction, not the next one ---------
        // This is the case that fails without the replay: the address for the
        // following instruction is already at memory when dispatch refuses.
        reset_dut();
        step(1'b0);                       // take word 0
        stall = 1'b1;
        #1;
        expect_eq ("stalled: still offering word 1", inst, 32'hC0DE_0001);
        expect_eq ("stalled: with its own pc",       pc,   BASE + 32'd4);
        expect_bit("stalled: still valid",           valid, 1'b1);
        @(negedge clk);
        #1;
        expect_eq("still offering word 1 a cycle later", inst, 32'hC0DE_0001);
        expect_eq("and the pc has not moved",            pc,   BASE + 32'd4);
        @(negedge clk);
        stall = 1'b0;
        #1;
        expect_eq("released: still word 1, not word 2", inst, 32'hC0DE_0001);
        @(negedge clk);
        #1;
        expect_eq("then word 2 follows", inst, 32'hC0DE_0002);

        // ---- NOTHING LOST OR REPEATED, with stalls at random -----------------
        reset_dut();
        n = 0;
        for (int i = 0; i < 400; i++) begin
            step($urandom_range(0, 2) == 0);
        end
        // Report WHERE, not just that. A scoreboard that only says "no" leaves
        // the reader to guess between a dropped instruction and a repeated one.
        ok = 1'b1;
        for (int i = 0; i < got_inst.size(); i++) begin
            if (ok && (got_inst[i] !== 32'hC0DE_0000 + 32'(i)
                       || got_pc[i] !== BASE + 32'(i) * 4)) begin
                ok = 1'b0;
                $display("  first divergence at %0d: got inst %08h pc %08h, want %08h %08h",
                         i, got_inst[i], got_pc[i],
                         32'hC0DE_0000 + 32'(i), BASE + 32'(i) * 4);
            end
        end
        expect_bit("random stalls lose and repeat nothing", ok, 1'b1);
        // And it did make progress rather than stalling forever.
        expect_bit("progress was made", (got_inst.size() > 100), 1'b1);
        $display("  (%0d instructions through %0d cycles of random stalling)",
                 got_inst.size(), 400);

        // ---- flush redirects, and nothing is valid until it lands -------------
        reset_dut();
        step(1'b0);
        step(1'b0);
        flush    = 1'b1;
        flush_pc = BASE + 32'd400;         // word 100
        @(negedge clk);
        flush = 1'b0;
        #1;
        expect_bit("nothing valid the cycle after a flush", valid, 1'b0);
        @(negedge clk);
        #1;
        expect_bit("valid once the redirected fetch returns", valid, 1'b1);
        expect_eq ("and it is the instruction at the target", inst, 32'hC0DE_0064);
        expect_eq ("with the target pc",                      pc, BASE + 32'd400);
        @(negedge clk);
        #1;
        expect_eq("then the one after it", inst, 32'hC0DE_0065);

        // ---- a flush during a stall discards the held instruction --------------
        // The held instruction is on the wrong path by definition, so replaying
        // it after a redirect would execute something the branch skipped.
        reset_dut();
        step(1'b0);
        stall = 1'b1;
        @(negedge clk);                    // capture the held instruction
        flush    = 1'b1;
        flush_pc = BASE + 32'd800;         // word 200
        @(negedge clk);
        flush = 1'b0;
        stall = 1'b0;
        #1;
        expect_bit("flush during a stall invalidates", valid, 1'b0);
        @(negedge clk);
        #1;
        expect_eq ("and the held instruction is gone", inst, 32'hC0DE_00c8);
        expect_bit("with the redirect valid",          valid, 1'b1);

        report("fetch");
    end

endmodule
