// Architectural register file, shared by both cores.
//
// WRITE_FIRST is what separates them. In a single-cycle core the read and the
// write in a given cycle belong to the SAME instruction, so bypassing the write
// value into the read ports would feed an instruction its own result -- a
// combinational loop, not a forwarding path. In a pipeline the write is from
// WB and the read from ID, four instructions apart, and without the bypass a
// read one cycle before the write returns stale data.
//
// Hence the parameter rather than one behaviour: single_cycle leaves it at 0,
// pipelined sets it to 1.

module regfile
import rv32i_types::*;
#(
    parameter bit WRITE_FIRST = 1'b0
)(
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

    logic bypass_rs1, bypass_rs2;

    assign bypass_rs1 = WRITE_FIRST && regf_we && (rd_s != '0) && (rd_s == rs1_s);
    assign bypass_rs2 = WRITE_FIRST && regf_we && (rd_s != '0) && (rd_s == rs2_s);

    // x0 is checked first: it reads zero even when an instruction nominally
    // targets it, which is also why the write above is suppressed for rd = x0.
    assign rs1_v = (rs1_s == '0) ? '0 : bypass_rs1 ? rd_v : data[rs1_s];
    assign rs2_v = (rs2_s == '0) ? '0 : bypass_rs2 ? rd_v : data[rs2_s];

endmodule
