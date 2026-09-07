// Single-cycle RV32I core. Fetch, decode, register read, execute, memory access
// and writeback all complete within one clock edge, so the only state is the
// program counter and the register file.
//
// Memory interface convention: dmem_addr is always word aligned and the byte
// lanes are chosen by dmem_rmask / dmem_wmask. Sub-word accesses therefore
// present the containing word's address with a narrow mask, and the load/store
// logic at the bottom of this file does the lane shifting on both sides.

module cpu
import rv32i_types::*;
#(
    parameter bit [31:0] RESET_PC = 32'h8000_0000
)(
    input  logic        clk,
    input  logic        rst,

    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_rmask,
    output logic [3:0]  dmem_wmask,
    input  logic [31:0] dmem_rdata,

    // Present for interface parity with the pipelined core, where halt
    // cannot be decoded from the fetch bus. Here every fetched
    // instruction is also a committed one, so it is just a decode.
    output logic        halt,

    // One instruction retires every cycle by construction.
    output logic        commit
);

    // ------------------------------------------------------------------
    // fetch
    // ------------------------------------------------------------------
    logic [31:0] pc, pc_next;
    logic [31:0] inst;
    logic [2:0]  funct3;

    assign inst      = imem_rdata;
    assign halt      = (inst == HALT_INST);
    assign commit    = ~rst;
    assign imem_addr = pc;
    assign funct3    = inst[14:12];

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= RESET_PC;
        end else begin
            pc <= pc_next;
        end
    end

    // ------------------------------------------------------------------
    // decode / control
    // ------------------------------------------------------------------
    alu_ops     aluop;
    alu_a_sel_t alu_a_sel;
    alu_b_sel_t alu_b_sel;
    imm_sel_t   imm_sel;
    wb_sel_t    wb_sel;
    logic       regf_we, mem_read, mem_write, is_branch, is_jal, is_jalr;
    logic       is_muldiv;

    control control_unit (.*);

    // Immediate assembly. The bit scrambling is the ISA's, not ours: the
    // formats are arranged so that the sign bit is always inst[31] and the
    // lower fields overlap between formats, which keeps the mux narrow.
    logic [31:0] imm;

    always_comb begin
        unique case (imm_sel)
            imm_i:   imm = {{20{inst[31]}}, inst[31:20]};
            imm_s:   imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};
            imm_b:   imm = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};
            imm_u:   imm = {inst[31:12], 12'b0};
            imm_j:   imm = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};
            default: imm = '0;
        endcase
    end

    // ------------------------------------------------------------------
    // register file
    // ------------------------------------------------------------------
    logic [31:0] rs1_v, rs2_v, rd_v;

    regfile regfile_inst (
        .clk    (clk),
        .rst    (rst),
        .regf_we(regf_we),
        .rd_v   (rd_v),
        .rs1_s  (inst[19:15]),
        .rs2_s  (inst[24:20]),
        .rd_s   (inst[11:7]),
        .rs1_v  (rs1_v),
        .rs2_v  (rs2_v)
    );

    // ------------------------------------------------------------------
    // execute
    // ------------------------------------------------------------------
    logic [31:0] alu_a, alu_b, alu_f;

    always_comb begin
        unique case (alu_a_sel)
            alu_a_rs1: alu_a = rs1_v;
            alu_a_pc:  alu_a = pc;
        endcase
        unique case (alu_b_sel)
            alu_b_rs2: alu_b = rs2_v;
            alu_b_imm: alu_b = imm;
        endcase
    end

    alu alu_inst (
        .aluop(aluop),
        .a    (alu_a),
        .b    (alu_b),
        .f    (alu_f)
    );

    // RV32M. SEQUENTIAL is 0 here and that is the whole point: a core whose
    // defining property is that every instruction retires in one cycle cannot
    // have an instruction that takes 34. The combinational divide costs about
    // 21 ns of critical path, five times what the rest of this core needs --
    // which is precisely the sort of thing the single-cycle design exists to
    // make visible rather than hide. mdu.sv carries the measurements.
    //
    // ready is tied high by construction in this configuration, so there is
    // nothing here to wait on and no handshake to get wrong.
    logic [31:0] md_result;
    /* verilator lint_off UNUSEDSIGNAL */
    // Constant 1 in this configuration, and connected only because a port has
    // to be. The pipelined core is where it means something.
    logic        md_ready;
    /* verilator lint_on UNUSEDSIGNAL */

    mdu #(
        .SEQUENTIAL (1'b0)
    ) mdu_inst (
        .clk    (clk),
        .rst    (rst),
        .req    (is_muldiv),
        .funct3 (funct3),
        .a      (rs1_v),
        .b      (rs2_v),
        .result (md_result),
        .ready  (md_ready)
    );

    // What execute produced, whichever unit produced it. Only writeback reads
    // this: the memory address and the branch target are always the ALU's, and
    // an M instruction is neither a load, a store, nor a branch.
    logic [31:0] ex_result;

    assign ex_result = is_muldiv ? md_result : alu_f;

    // Branches compare the raw register values rather than reusing the ALU,
    // because the ALU is busy computing the branch target this cycle.
    logic branch_taken;

    always_comb begin
        unique case (branch_f3_t'(funct3))
            branch_f3_beq:  branch_taken = (rs1_v == rs2_v);
            branch_f3_bne:  branch_taken = (rs1_v != rs2_v);
            branch_f3_blt:  branch_taken = (signed'(rs1_v) <  signed'(rs2_v));
            branch_f3_bge:  branch_taken = (signed'(rs1_v) >= signed'(rs2_v));
            branch_f3_bltu: branch_taken = (rs1_v <  rs2_v);
            branch_f3_bgeu: branch_taken = (rs1_v >= rs2_v);
            default:        branch_taken = 1'b0;   // funct3 011 and 111 are unused
        endcase
    end

    // The ALU has already produced pc + imm for jal and branches, and rs1 + imm
    // for jalr. jalr additionally clears bit 0, which the ISA mandates.
    always_comb begin
        if (is_jal || (is_branch && branch_taken)) begin
            pc_next = alu_f;
        end else if (is_jalr) begin
            pc_next = {alu_f[31:1], 1'b0};
        end else begin
            pc_next = pc + 32'd4;
        end
    end

    // ------------------------------------------------------------------
    // memory access
    // ------------------------------------------------------------------
    logic [1:0] byte_off;
    logic [3:0] size_mask;

    assign byte_off  = alu_f[1:0];
    assign dmem_addr = {alu_f[31:2], 2'b00};

    // funct3[1:0] encodes the width identically for loads and stores: 00 byte,
    // 01 halfword, 10 word. 11 is not a legal width in RV32I.
    always_comb begin
        unique case (funct3[1:0])
            2'b00:   size_mask = 4'b0001;
            2'b01:   size_mask = 4'b0011;
            2'b10:   size_mask = 4'b1111;
            default: size_mask = 4'b0000;
        endcase
    end

    assign dmem_rmask = mem_read  ? (size_mask << byte_off) : 4'b0000;
    assign dmem_wmask = mem_write ? (size_mask << byte_off) : 4'b0000;
    assign dmem_wdata = rs2_v << {byte_off, 3'b000};

    // Loads come back as the whole word; shift the addressed lane down, then
    // extend it according to funct3.
    logic [31:0] load_word;
    logic [31:0] load_data;

    assign load_word = dmem_rdata >> {byte_off, 3'b000};

    always_comb begin
        unique case (load_f3_t'(funct3))
            load_f3_lb:  load_data = {{24{load_word[7]}},  load_word[7:0]};
            load_f3_lh:  load_data = {{16{load_word[15]}}, load_word[15:0]};
            load_f3_lw:  load_data = load_word;
            load_f3_lbu: load_data = {24'b0, load_word[7:0]};
            load_f3_lhu: load_data = {16'b0, load_word[15:0]};
            default:     load_data = load_word;
        endcase
    end

    // ------------------------------------------------------------------
    // writeback
    // ------------------------------------------------------------------
    always_comb begin
        unique case (wb_sel)
            wb_alu: rd_v = ex_result;
            wb_mem: rd_v = load_data;
            wb_pc4: rd_v = pc + 32'd4;
            wb_imm: rd_v = imm;
        endcase
    end

endmodule
