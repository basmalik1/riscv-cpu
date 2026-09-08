// dispatch: rename, and the all-or-nothing rule.
//
// The property everything else depends on is that no write port ever fires
// alone. An instruction that takes a physical register and then finds no
// reorder buffer slot has leaked that register: nothing holds it, nothing will
// free it, and the machine dies when the pool runs dry -- thousands of cycles
// later, with no connection to the cause. So most of this file knocks out one
// resource at a time and checks that ALL five enables stay low, not just the
// one belonging to the missing resource.
//
// control.sv is instantiated rather than hand-decoded. Writing the control
// signals out by hand here would test this module against my reading of the
// encoding instead of against the decoder the core actually uses.

module tb_dispatch
import rv32i_types::*;
import ooo_types::*;
;

    `include "tb_check.svh"

    logic [31:0] inst, pc;
    logic        valid;

    // decoded by the real decoder
    alu_ops     aluop;
    alu_a_sel_t alu_a_sel;
    alu_b_sel_t alu_b_sel;
    imm_sel_t   imm_sel;
    wb_sel_t    wb_sel;
    logic       regf_we, mem_read, mem_write, is_branch, is_jal, is_jalr, is_muldiv;

    control ctrl (
        .inst(inst), .aluop(aluop), .alu_a_sel(alu_a_sel), .alu_b_sel(alu_b_sel),
        .imm_sel(imm_sel), .wb_sel(wb_sel), .regf_we(regf_we),
        .mem_read(mem_read), .mem_write(mem_write), .is_branch(is_branch),
        .is_jal(is_jal), .is_jalr(is_jalr), .is_muldiv(is_muldiv));

    // what the structures answer
    logic [5:0] rat_rs1_tag, rat_rs2_tag, rat_rd_old_tag;
    logic       prf_rs1_ready, prf_rs2_ready;
    logic [5:0] free_tag;
    logic       free_valid, rob_ready, iq_ready;
    logic [4:0] rob_idx;

    // what dispatch drives
    logic        fire, ready;
    logic [4:0]  rs1_addr, rs2_addr, rat_rd_addr, rob_rd_arch;
    logic [5:0]  prf_rs1_tag, prf_rs2_tag, rat_rd_tag, prf_alloc_tag;
    logic [5:0]  rob_rd_phys, rob_rd_old_phys;
    logic        free_alloc, rat_we, prf_alloc, rob_alloc, iq_dispatch;
    logic        rob_writes_reg, rob_is_halt;
    logic [31:0] rob_pc;
    logic [5:0]  iq_rs1, iq_rs2;
    logic        iq_rs1_ready, iq_rs2_ready;
    iq_payload_t iq_payload;

    dispatch dut (.*);

    // Everything available, so `fire` follows `valid` alone.
    task automatic all_resources();
        rat_rs1_tag    = 6'd10;
        rat_rs2_tag    = 6'd11;
        rat_rd_old_tag = 6'd12;
        prf_rs1_ready  = 1'b1;
        prf_rs2_ready  = 1'b1;
        free_tag       = 6'd40;
        free_valid     = 1'b1;
        rob_ready      = 1'b1;
        iq_ready       = 1'b1;
        rob_idx        = 5'd7;
        valid          = 1'b1;
    endtask

    // The check that matters: not one write port may be enabled.
    task automatic expect_nothing_fires(string why);
        expect_bit({why, ": no fire"},       fire,        1'b0);
        expect_bit({why, ": no tag taken"},  free_alloc,  1'b0);
        expect_bit({why, ": no rat write"},  rat_we,      1'b0);
        expect_bit({why, ": no prf alloc"},  prf_alloc,   1'b0);
        expect_bit({why, ": no rob alloc"},  rob_alloc,   1'b0);
        expect_bit({why, ": no iq push"},    iq_dispatch, 1'b0);
    endtask

    initial begin
        // ---- a plain register-writing instruction ------------------------
        // addi x1, x2, 5
        inst = 32'h00510093;
        pc   = 32'h8000_0000;
        all_resources();
        #1;
        expect_bit("addi fires",              fire,        1'b1);
        expect_bit("addi takes a tag",        free_alloc,  1'b1);
        expect_bit("addi writes the rat",     rat_we,      1'b1);
        expect_bit("addi allocates in prf",   prf_alloc,   1'b1);
        expect_bit("addi allocates in rob",   rob_alloc,   1'b1);
        expect_bit("addi pushes to the iq",   iq_dispatch, 1'b1);

        expect_eq ("reads rs1 from the instruction", {27'd0, rs1_addr}, 32'd2);
        expect_eq ("renames rd",                {27'd0, rat_rd_addr}, 32'd1);
        expect_eq ("rd gets the free tag",      {26'd0, rat_rd_tag},  32'd40);
        expect_eq ("prf is allocated the same tag",
                   {26'd0, prf_alloc_tag}, 32'd40);
        // The register file is read at the tags the alias table just gave, so
        // the ready bits belong to this instruction's sources.
        expect_eq ("prf read port 1 follows the rat", {26'd0, prf_rs1_tag}, 32'd10);
        expect_eq ("prf read port 2 follows the rat", {26'd0, prf_rs2_tag}, 32'd11);

        // What the reorder buffer is told: its own tag, and the one it
        // displaces, which is what commit will release.
        expect_eq ("rob told the new tag",       {26'd0, rob_rd_phys},     32'd40);
        expect_eq ("rob told the displaced tag", {26'd0, rob_rd_old_phys}, 32'd12);
        expect_bit("rob told it writes a register", rob_writes_reg, 1'b1);
        expect_eq ("rob told the pc",            rob_pc, 32'h8000_0000);

        // ---- ALL OR NOTHING ------------------------------------------------
        // Each resource removed on its own. Every enable must go low, not just
        // the one that belongs to the missing resource.
        all_resources(); free_valid = 1'b0; #1;
        expect_nothing_fires("no free tag");

        all_resources(); rob_ready = 1'b0; #1;
        expect_nothing_fires("rob full");

        all_resources(); iq_ready = 1'b0; #1;
        expect_nothing_fires("issue queue full");

        all_resources(); valid = 1'b0; #1;
        expect_nothing_fires("no instruction");

        // Two at once, for good measure.
        all_resources(); rob_ready = 1'b0; iq_ready = 1'b0; #1;
        expect_nothing_fires("rob and iq both full");

        // ---- `ready` is about resources, not about the instruction ---------
        // The front end needs to know whether to hold the instruction, which
        // is a different question from whether one was presented.
        all_resources(); valid = 1'b0; #1;
        expect_bit("no instruction still leaves room", ready, 1'b1);
        all_resources(); rob_ready = 1'b0; #1;
        expect_bit("a full rob means not ready", ready, 1'b0);

        // ---- an instruction with no destination allocates nothing -----------
        // sw x3, 0(x2). No register written, so no tag, no alias entry -- but
        // it still takes a reorder buffer slot, because it still has to commit
        // in order.
        inst = 32'h00312023;
        all_resources();
        #1;
        expect_bit("store fires",               fire,        1'b1);
        expect_bit("store takes no tag",        free_alloc,  1'b0);
        expect_bit("store writes no rat entry", rat_we,      1'b0);
        expect_bit("store allocates no prf",    prf_alloc,   1'b0);
        expect_bit("store still enters the rob", rob_alloc,  1'b1);
        expect_bit("store still enters the iq",  iq_dispatch, 1'b1);
        expect_bit("rob told it writes nothing", rob_writes_reg, 1'b0);
        expect_bit("payload agrees it writes nothing",
                   iq_payload.writes_reg, 1'b0);

        // And with no free tag available a store must STILL dispatch, because
        // it never needed one. A machine that stalled here would deadlock the
        // moment the pool emptied, since only commits refill it.
        all_resources(); free_valid = 1'b0; #1;
        expect_bit("store dispatches without a free tag", fire, 1'b1);
        expect_bit("and still takes none",                free_alloc, 1'b0);

        // ---- a destination of x0 allocates nothing either --------------------
        // addi x0, x2, 5. The ISA discards it, so it must not consume a
        // physical register -- and the alias table must not be told about it.
        inst = 32'h00510013;
        all_resources();
        #1;
        expect_bit("x0 destination fires",          fire,       1'b1);
        expect_bit("x0 destination takes no tag",   free_alloc, 1'b0);
        expect_bit("x0 destination writes no rat",  rat_we,     1'b0);
        expect_bit("x0 destination allocates no prf", prf_alloc, 1'b0);
        expect_bit("rob told x0 writes nothing",    rob_writes_reg, 1'b0);
        // The payload carries the same fact separately, and execute reads THAT
        // one when deciding whether to broadcast a result.
        expect_bit("payload agrees x0 writes nothing",
                   iq_payload.writes_reg, 1'b0);
        expect_bit("but it still enters the rob",   rob_alloc,  1'b1);

        // ---- the halt convention rides through --------------------------------
        inst = HALT_INST;
        all_resources();
        #1;
        // Only the reorder buffer is told. The payload has no copy, so there
        // is one place the fact lives.
        expect_bit("halt is flagged to the rob", rob_is_halt, 1'b1);
        inst = 32'h00510093;
        #1;
        expect_bit("an ordinary instruction is not", rob_is_halt, 1'b0);

        // ---- immediates, one per format ----------------------------------------
        all_resources();
        inst = 32'h00510093; #1;                     // addi x1, x2, 5
        expect_eq("I-type immediate", iq_payload.imm, 32'd5);

        inst = 32'hfff10093; #1;                     // addi x1, x2, -1
        expect_eq("I-type negative", iq_payload.imm, 32'hffff_ffff);

        inst = 32'h00312023; #1;                     // sw x3, 0(x2)
        expect_eq("S-type immediate zero", iq_payload.imm, 32'd0);

        // A non-zero one, because the S-type immediate is split across two
        // fields and an offset of zero is identical however they are
        // reassembled. Twenty is 0b10100: entirely in the low field, so a
        // swap moves it seven bits and is unmistakable.
        inst = 32'h00312a23; #1;                     // sw x3, 20(x2)
        expect_eq("S-type immediate reassembled", iq_payload.imm, 32'd20);

        inst = 32'h123450b7; #1;                     // lui x1, 0x12345
        expect_eq("U-type immediate", iq_payload.imm, 32'h1234_5000);

        // ---- the payload carries what execute needs -----------------------------
        inst = 32'h00510093;
        all_resources();
        #1;
        expect_eq ("payload carries the rob index",  {27'd0, iq_payload.rob_idx}, 32'd7);
        expect_eq ("payload carries the destination",
                   {26'd0, iq_payload.rd_phys}, 32'd40);
        expect_bit("payload says it writes",         iq_payload.writes_reg, 1'b1);
        expect_eq ("payload carries rs1 for the prf read",
                   {26'd0, iq_payload.rs1_phys}, 32'd10);
        expect_eq ("payload carries rs2 for the prf read",
                   {26'd0, iq_payload.rs2_phys}, 32'd11);
        expect_eq ("payload carries the pc",         iq_payload.pc, 32'h8000_0000);
        expect_eq ("payload carries the alu op",
                   {28'd0, iq_payload.aluop}, {28'd0, alu_op_add});

        // ---- the issue queue is told the readiness of the real sources ----------
        all_resources(); prf_rs1_ready = 1'b0; #1;
        expect_eq ("iq told rs1's tag",   {26'd0, iq_rs1}, 32'd10);
        expect_eq ("iq told rs2's tag",   {26'd0, iq_rs2}, 32'd11);
        expect_bit("iq told rs1 waits",   iq_rs1_ready, 1'b0);
        expect_bit("iq told rs2 is ready", iq_rs2_ready, 1'b1);

        // A source that is not ready must not stop dispatch -- waiting is the
        // issue queue's job, and stalling here would make the machine in-order.
        expect_bit("an unready source still dispatches", fire, 1'b1);

        report("dispatch");
    end

endmodule
