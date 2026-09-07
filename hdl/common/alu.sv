module alu
import rv32i_types::*;
(
    input  alu_ops      aluop,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] f
);

    logic signed   [31:0] as;
    logic signed   [31:0] bs;
    logic unsigned [31:0] au;
    logic unsigned [31:0] bu;

    assign as = signed'(a);
    assign bs = signed'(b);
    assign au = unsigned'(a);
    assign bu = unsigned'(b);

    always_comb begin
        unique case (aluop)
            alu_op_add:  f = au +   bu;
            alu_op_sub:  f = au -   bu;
            alu_op_sll:  f = au <<  bu[4:0];
            alu_op_srl:  f = au >>  bu[4:0];
            alu_op_sra:  f = unsigned'(as >>> bu[4:0]);
            alu_op_xor:  f = au ^   bu;
            alu_op_or:   f = au |   bu;
            alu_op_and:  f = au &   bu;
            alu_op_slt:  f = {31'd0, as <  bs};
            alu_op_sltu: f = {31'd0, au <  bu};
            default:     f = 'x;
        endcase
    end

endmodule
