module top_tb
import rv32i_types::*;
#(
    parameter bit [31:0]   MEM_BASE = 32'h8000_0000,
    parameter int unsigned MEM_SIZE = 32'h0001_0000
)(
    input logic clk,
    input logic rst
);

    `include "top_tb.svh"

endmodule
