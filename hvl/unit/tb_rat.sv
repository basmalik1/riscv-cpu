// rat: the architectural-to-physical mapping.
//
// Three things here are worth more than the table lookups.
//
// Read-first, which is the opposite of what regfile.sv does and is easy to get
// backwards. `add x1, x1, x2` must read the OLD x1 and write a new mapping in
// the same cycle; a write-first table hands it the tag it is about to define
// and produces an instruction depending on itself. Nothing downstream can
// recover from that, and no simple program reveals it -- only one where the
// destination is also a source.
//
// rd_old_tag, which is what commit later uses to decide which physical
// register to release. Reporting the new tag instead of the displaced one
// frees a register that architectural state still owns, and the damage lands
// on whatever instruction is unlucky enough to be given it next.
//
// x0, which must survive being written to.

module tb_rat;

    `include "tb_check.svh"

    localparam int unsigned PHYS = 64;
    localparam int unsigned ARCH = 32;

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    logic [4:0] rs1_addr, rs2_addr, rd_addr;
    logic [5:0] rs1_tag, rs2_tag, rd_tag, rd_old_tag;
    logic       we;

    rat #(.PHYS_REGS(PHYS), .ARCH_REGS(ARCH)) dut (.*);

    // What the mapping should be, tracked independently.
    logic [5:0] model [ARCH];

    task automatic write_map(logic [4:0] a, logic [5:0] p);
        rd_addr = a;
        rd_tag  = p;
        we      = 1'b1;
        @(negedge clk);
        we = 1'b0;
        if (a != 5'd0) begin
            model[a] = p;
        end
    endtask

    task automatic reset_dut();
        rst = 1'b1; we = 1'b0;
        rs1_addr = '0; rs2_addr = '0; rd_addr = '0; rd_tag = '0;
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (int i = 0; i < int'(ARCH); i++) begin
            model[i] = 6'(i);
        end
        @(negedge clk);
    endtask

    logic [5:0] expect_tag;
    int         a, p;

    initial begin
        reset_dut();

        // ---- reset is the identity mapping ---------------------------------
        // The free list depends on this: it comes up holding exactly the tags
        // from ARCH upward, so if the table did not start at the identity the
        // two would disagree about who owns the low physical registers.
        for (int i = 0; i < int'(ARCH); i++) begin
            rs1_addr = 5'(i);
            #1;
            expect_eq("reset maps arch i to phys i", {26'd0, rs1_tag}, 32'(i));
        end

        // ---- a plain remap --------------------------------------------------
        write_map(5'd7, 6'd40);
        rs1_addr = 5'd7; #1;
        expect_eq("remapped x7", {26'd0, rs1_tag}, 32'd40);

        rs2_addr = 5'd8; #1;
        expect_eq("neighbour untouched", {26'd0, rs2_tag}, 32'd8);

        // ---- both read ports are independent --------------------------------
        write_map(5'd8, 6'd41);
        rs1_addr = 5'd7; rs2_addr = 5'd8; #1;
        expect_eq("port 1", {26'd0, rs1_tag}, 32'd40);
        expect_eq("port 2", {26'd0, rs2_tag}, 32'd41);

        // ---- rd_old_tag reports what is being displaced ----------------------
        rd_addr = 5'd7; #1;
        expect_eq("old tag before overwrite", {26'd0, rd_old_tag}, 32'd40);
        write_map(5'd7, 6'd50);
        rd_addr = 5'd7; #1;
        expect_eq("old tag after overwrite", {26'd0, rd_old_tag}, 32'd50);

        // ---- READ-FIRST, the case that matters -------------------------------
        // Drive a write to x9 while reading x9 on both source ports in the same
        // cycle, which is exactly `add x9, x9, x9` at rename. Every read must
        // see the mapping that existed before this instruction, and rd_old_tag
        // must report it too.
        write_map(5'd9, 6'd33);

        rd_addr  = 5'd9;
        rd_tag   = 6'd44;
        rs1_addr = 5'd9;
        rs2_addr = 5'd9;
        we       = 1'b1;
        #1;
        expect_eq("read-first: rs1 sees the old tag",  {26'd0, rs1_tag},    32'd33);
        expect_eq("read-first: rs2 sees the old tag",  {26'd0, rs2_tag},    32'd33);
        expect_eq("read-first: old tag is the old one", {26'd0, rd_old_tag}, 32'd33);
        @(negedge clk);
        we = 1'b0;
        model[9] = 6'd44;

        // And the write did land.
        rs1_addr = 5'd9; #1;
        expect_eq("read-first: write took effect next cycle", {26'd0, rs1_tag}, 32'd44);

        // ---- x0 cannot be remapped -------------------------------------------
        // Rename is expected not to allocate for a destination of x0 at all,
        // but the guard is what makes that safe rather than a convention that
        // one careless caller breaks.
        write_map(5'd0, 6'd63);
        rs1_addr = 5'd0; #1;
        expect_eq("x0 still maps to phys 0", {26'd0, rs1_tag}, 32'd0);
        rd_addr = 5'd0; #1;
        expect_eq("x0 old tag is phys 0",    {26'd0, rd_old_tag}, 32'd0);

        // A write to x0 must not disturb anything else either.
        rs1_addr = 5'd9; #1;
        expect_eq("x0 write left x9 alone", {26'd0, rs1_tag}, 32'd44);

        // ---- we low changes nothing -------------------------------------------
        rd_addr = 5'd9;
        rd_tag  = 6'd55;
        we      = 1'b0;
        @(negedge clk);
        rs1_addr = 5'd9; #1;
        expect_eq("no write without we", {26'd0, rs1_tag}, 32'd44);

        // ---- reset restores the identity from an arbitrary state ---------------
        reset_dut();
        for (int i = 0; i < int'(ARCH); i++) begin
            rs1_addr = 5'(i);
            #1;
            expect_eq("reset restores identity", {26'd0, rs1_tag}, 32'(i));
        end

        // ---- a long random run against the model --------------------------------
        // Every cycle, a random remap and two random lookups, checked against an
        // independently maintained model. This is what catches an off-by-one in
        // the index or a write that lands on the wrong entry.
        for (int i = 0; i < 2000; i++) begin
            a = $urandom_range(0, int'(ARCH) - 1);
            p = $urandom_range(int'(ARCH), int'(PHYS) - 1);

            rs1_addr = 5'($urandom_range(0, int'(ARCH) - 1));
            rs2_addr = 5'($urandom_range(0, int'(ARCH) - 1));
            rd_addr  = 5'(a);
            rd_tag   = 6'(p);
            we       = ($urandom_range(0, 3) != 0);
            #1;

            expect_eq("random: rs1", {26'd0, rs1_tag},    {26'd0, model[rs1_addr]});
            expect_eq("random: rs2", {26'd0, rs2_tag},    {26'd0, model[rs2_addr]});
            expect_eq("random: old", {26'd0, rd_old_tag}, {26'd0, model[rd_addr]});

            @(negedge clk);
            if (we && a != 0) begin
                model[a] = 6'(p);
            end
            we = 1'b0;
        end

        // Whatever the random run left behind must still match entry for entry.
        for (int i = 0; i < int'(ARCH); i++) begin
            rs1_addr = 5'(i);
            #1;
            expect_eq("final state matches the model",
                      {26'd0, rs1_tag}, {26'd0, model[i]});
        end

        report("rat");
    end

endmodule
