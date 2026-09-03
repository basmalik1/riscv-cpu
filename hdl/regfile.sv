module regfile
import rv32i_types::*;
(
    input  logic                 clk,
    input  logic                 rst,

    input  logic                 regf_we,
    input  logic [31:0]          rd_v,
    input  logic [REG_BITS-1:0]  rs1_s,
    input  logic [REG_BITS-1:0]  rs2_s,
    input  logic [REG_BITS-1:0]  rd_s,

    output logic [31:0]          rs1_v,
    output logic [31:0]          rs2_v
);

    logic [31:0] data [REG_COUNT];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < int'(REG_COUNT); i++) begin
                data[i] <= '0;
            end
        end else if (regf_we && rd_s != '0) begin
            data[rd_s] <= rd_v;
        end
    end

    // No write-first bypass: in a single-cycle core the read and the write in a
    // given cycle belong to the same instruction, so forwarding would be wrong.
    assign rs1_v = (rs1_s == '0) ? '0 : data[rs1_s];
    assign rs2_v = (rs2_s == '0) ? '0 : data[rs2_s];

endmodule
