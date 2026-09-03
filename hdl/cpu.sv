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
    input  logic [31:0] dmem_rdata
);

    logic [31:0] pc, pc_next;
    logic [31:0] inst;

    assign inst      = imem_rdata;
    assign imem_addr = pc;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= RESET_PC;
        end else begin
            pc <= pc_next;
        end
    end

    // TODO: select the jump/branch target when is_jal, is_jalr, or a taken
    // branch; fall through to pc + 4 otherwise.
    assign pc_next = pc + 32'd4;

    // ------------------------------------------------------------------
    // decode / control
    // ------------------------------------------------------------------
    alu_ops     aluop;
    alu_a_sel_t alu_a_sel;
    alu_b_sel_t alu_b_sel;
    imm_sel_t   imm_sel;
    wb_sel_t    wb_sel;
    logic       regf_we, mem_read, mem_write, is_branch, is_jal, is_jalr;

    control control_unit (.*);

    // TODO: build the immediate selected by imm_sel out of `inst`.
    logic [31:0] imm;
    assign imm = '0;

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

    // TODO: mux rd_v on wb_sel — alu_f, the aligned load data, pc + 4, or imm.
    assign rd_v = '0;

    // ------------------------------------------------------------------
    // execute
    // ------------------------------------------------------------------
    logic [31:0] alu_a, alu_b, alu_f;

    // TODO: drive these from alu_a_sel / alu_b_sel.
    assign alu_a = rs1_v;
    assign alu_b = rs2_v;

    alu alu_inst (
        .aluop(aluop),
        .a    (alu_a),
        .b    (alu_b),
        .f    (alu_f)
    );

    // TODO: compare rs1_v against rs2_v per funct3 to resolve is_branch.

    // ------------------------------------------------------------------
    // memory access
    // ------------------------------------------------------------------
    // TODO: dmem_addr is the word-aligned alu_f; shift wdata into the correct
    // byte lane and build rmask/wmask from funct3 and alu_f[1:0]. Loads then
    // need sign/zero extension of the selected lane on the way back.
    assign dmem_addr  = '0;
    assign dmem_wdata = '0;
    assign dmem_rmask = '0;
    assign dmem_wmask = '0;

endmodule
