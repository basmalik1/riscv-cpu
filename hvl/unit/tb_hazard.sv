// hazard: every forwarding and stall decision in the core.
//
// The densest logic in the design and the least visible in a waveform, which
// makes it the stage most worth testing directly rather than through programs.

module tb_hazard
import rv32i_types::*;
import pipelined_types::*;
;

    `include "tb_check.svh"

    logic        id_valid;
    rv32i_opcode id_opcode;
    logic [4:0]  id_rs1_s, id_rs2_s;
    id_ex_t      id_ex;
    ex_mem_t     ex_mem;
    mem_wb_t     mem_wb;
    fwd_sel_t    fwd_a, fwd_b;
    logic        stall;

    hazard dut (.*);

    task automatic clear();
        id_valid  = 1'b1;
        id_opcode = op_b_reg;
        id_rs1_s  = 5'd0;
        id_rs2_s  = 5'd0;
        id_ex     = '0;
        ex_mem    = '0;
        mem_wb    = '0;
    endtask

    // An instruction sitting in MEM that will write rd.
    task automatic mem_writes(logic [4:0] rd, wb_sel_t sel);
        ex_mem.valid   = 1'b1;
        ex_mem.regf_we = 1'b1;
        ex_mem.rd_s    = rd;
        ex_mem.wb_sel  = sel;
    endtask

    task automatic wb_writes(logic [4:0] rd);
        mem_wb.valid   = 1'b1;
        mem_wb.regf_we = 1'b1;
        mem_wb.rd_s    = rd;
        mem_wb.wb_sel  = wb_alu;
    endtask

    initial begin
        // ---- no hazard, no forwarding ------------------------------------
        clear();
        id_ex.valid = 1'b1;
        id_ex.rs1_s = 5'd1;
        id_ex.rs2_s = 5'd2;
        #1;
        expect_eq("idle fwd_a", {30'd0, fwd_a}, {30'd0, fwd_none});
        expect_eq("idle fwd_b", {30'd0, fwd_b}, {30'd0, fwd_none});
        expect_bit("idle no stall", stall, 1'b0);

        // ---- forward from MEM --------------------------------------------
        clear();
        id_ex.valid = 1'b1;
        id_ex.rs1_s = 5'd7;
        mem_writes(5'd7, wb_alu);
        #1;
        expect_eq("fwd_a from MEM", {30'd0, fwd_a}, {30'd0, fwd_mem});

        // ---- forward from WB ---------------------------------------------
        clear();
        id_ex.valid = 1'b1;
        id_ex.rs2_s = 5'd9;
        wb_writes(5'd9);
        #1;
        expect_eq("fwd_b from WB", {30'd0, fwd_b}, {30'd0, fwd_wb});

        // ---- both match: MEM is the more recent write and must win --------
        clear();
        id_ex.valid = 1'b1;
        id_ex.rs1_s = 5'd5;
        mem_writes(5'd5, wb_alu);
        wb_writes(5'd5);
        #1;
        expect_eq("MEM beats WB", {30'd0, fwd_a}, {30'd0, fwd_mem});

        // ---- x0 is never forwarded: it reads zero no matter what ----------
        clear();
        id_ex.valid = 1'b1;
        id_ex.rs1_s = 5'd0;
        mem_writes(5'd0, wb_alu);
        #1;
        expect_eq("x0 not forwarded", {30'd0, fwd_a}, {30'd0, fwd_none});

        // ---- an instruction that writes no register forwards nothing ------
        clear();
        id_ex.valid    = 1'b1;
        id_ex.rs1_s    = 5'd4;
        ex_mem.valid   = 1'b1;
        ex_mem.regf_we = 1'b0;
        ex_mem.rd_s    = 5'd4;
        #1;
        expect_eq("no regf_we no fwd", {30'd0, fwd_a}, {30'd0, fwd_none});

        // ---- a bubble in MEM forwards nothing -----------------------------
        clear();
        id_ex.valid  = 1'b1;
        id_ex.rs1_s  = 5'd4;
        mem_writes(5'd4, wb_alu);
        ex_mem.valid = 1'b0;
        #1;
        expect_eq("bubble does not fwd", {30'd0, fwd_a}, {30'd0, fwd_none});

        // ---- a load in MEM has no value yet -------------------------------
        // Unreachable in the assembled core, since the stall below keeps a
        // consumer in ID until the load reaches WB. Checked anyway so the
        // failure mode on a broken stall is "no forward" and not "forward the
        // address".
        clear();
        id_ex.valid = 1'b1;
        id_ex.rs1_s = 5'd6;
        mem_writes(5'd6, wb_mem);
        #1;
        expect_eq("load in MEM not fwd", {30'd0, fwd_a}, {30'd0, fwd_none});

        // ---- load-use: the one hazard forwarding cannot cover -------------
        clear();
        id_ex.valid    = 1'b1;
        id_ex.mem_read = 1'b1;
        id_ex.rd_s     = 5'd3;
        id_opcode      = op_b_reg;
        id_rs1_s       = 5'd3;
        #1;
        expect_bit("load-use on rs1 stalls", stall, 1'b1);

        clear();
        id_ex.valid    = 1'b1;
        id_ex.mem_read = 1'b1;
        id_ex.rd_s     = 5'd3;
        id_opcode      = op_b_reg;
        id_rs2_s       = 5'd3;
        #1;
        expect_bit("load-use on rs2 stalls", stall, 1'b1);

        // ---- and the cases that must NOT stall ----------------------------
        clear();
        id_ex.valid    = 1'b1;
        id_ex.mem_read = 1'b1;
        id_ex.rd_s     = 5'd3;
        id_rs1_s       = 5'd8;
        id_rs2_s       = 5'd9;
        #1;
        expect_bit("unrelated load no stall", stall, 1'b0);

        // lui, auipc and jal put immediate bits where rs1/rs2 would be, so a
        // coincidental match there must not stall.
        clear();
        id_ex.valid    = 1'b1;
        id_ex.mem_read = 1'b1;
        id_ex.rd_s     = 5'd3;
        id_opcode      = op_b_lui;
        id_rs1_s       = 5'd3;
        #1;
        expect_bit("lui does not read rs1", stall, 1'b0);

        clear();
        id_ex.valid    = 1'b1;
        id_ex.mem_read = 1'b1;
        id_ex.rd_s     = 5'd3;
        id_opcode      = op_b_jal;
        id_rs1_s       = 5'd3;
        #1;
        expect_bit("jal does not read rs1", stall, 1'b0);

        // An I-type reads rs1 but not rs2.
        clear();
        id_ex.valid    = 1'b1;
        id_ex.mem_read = 1'b1;
        id_ex.rd_s     = 5'd3;
        id_opcode      = op_b_imm;
        id_rs2_s       = 5'd3;
        #1;
        expect_bit("addi does not read rs2", stall, 1'b0);

        // A load targeting x0 discards its result, so nothing depends on it.
        clear();
        id_ex.valid    = 1'b1;
        id_ex.mem_read = 1'b1;
        id_ex.rd_s     = 5'd0;
        id_rs1_s       = 5'd0;
        #1;
        expect_bit("load to x0 no stall", stall, 1'b0);

        // Nothing in ID means nothing to stall.
        clear();
        id_valid       = 1'b0;
        id_ex.valid    = 1'b1;
        id_ex.mem_read = 1'b1;
        id_ex.rd_s     = 5'd3;
        id_rs1_s       = 5'd3;
        #1;
        expect_bit("empty ID no stall", stall, 1'b0);

        report("hazard");
    end

endmodule
