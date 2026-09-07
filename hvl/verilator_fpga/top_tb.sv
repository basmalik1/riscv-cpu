// Drives fpga/top_de10lite.sv as the board would: one free-running 50 MHz
// clock and KEY0 as reset. Nothing else is connected.
//
// The point is to prove the phase-counter timing in the FPGA top actually
// carries hdl/cpu.sv, using the same programs the simulation build runs, before
// any of it reaches hardware. If this passes, the only untested parts of the
// board flow are pin assignments and Quartus itself.
//
// Named top_tb so it reuses hvl/verilator/verilator_harness.cpp unchanged.

module top_tb #(
    parameter bit [31:0]   MEM_BASE = 32'h8000_0000,
    parameter int unsigned MEM_SIZE = 32'h0001_0000
)(
    input logic clk,        // 50 MHz board clock
    input logic rst
);

    logic [1:0] key;
    logic [9:0] ledr;
    logic [7:0] hex0, hex1, hex2, hex3, hex4, hex5;

    assign key = {1'b1, ~rst};      // KEY0 is active low

    top_de10lite #(
        .MEM_BASE      (MEM_BASE),
        .MEM_SIZE      (MEM_SIZE)
    ) dut (
        .MAX10_CLK1_50 (clk),
        .KEY           (key),
        .SW            (10'b0),
        .LEDR          (ledr),
        .HEX0          (hex0),
        .HEX1          (hex1),
        .HEX2          (hex2),
        .HEX3          (hex3),
        .HEX4          (hex4),
        .HEX5          (hex5)
    );

    // The seven segment displays are the only way to read anything off the
    // board, so decode them back and confirm they show the PC. A wrong segment
    // map would leave the demo unreadable with nothing to indicate why.
    function automatic logic [3:0] seg_decode(logic [7:0] s);
        unique case (s)
            8'b1100_0000: seg_decode = 4'h0;
            8'b1111_1001: seg_decode = 4'h1;
            8'b1010_0100: seg_decode = 4'h2;
            8'b1011_0000: seg_decode = 4'h3;
            8'b1001_1001: seg_decode = 4'h4;
            8'b1001_0010: seg_decode = 4'h5;
            8'b1000_0010: seg_decode = 4'h6;
            8'b1111_1000: seg_decode = 4'h7;
            8'b1000_0000: seg_decode = 4'h8;
            8'b1001_0000: seg_decode = 4'h9;
            8'b1000_1000: seg_decode = 4'ha;
            8'b1000_0011: seg_decode = 4'hb;
            8'b1100_0110: seg_decode = 4'hc;
            8'b1010_0001: seg_decode = 4'hd;
            8'b1000_0110: seg_decode = 4'he;
            8'b1000_1110: seg_decode = 4'hf;
            default:      seg_decode = 4'hx;
        endcase
    endfunction

    logic [23:0] displayed;

    assign displayed = {seg_decode(hex5), seg_decode(hex4), seg_decode(hex3),
                        seg_decode(hex2), seg_decode(hex1), seg_decode(hex0)};

    longint timeout;
    longint cycles;

    initial begin
        if (!$value$plusargs("TIMEOUT=%d", timeout)) begin
            $fatal(1, "TB Error: +TIMEOUT=<cycles> was not provided");
        end
        cycles = 0;
    end

    // Counts board cycles, so expect roughly four per instruction.
    always @(posedge clk) begin
        if (!rst) begin
            if (displayed !== dut.imem_addr[23:0]) begin
                $fatal(1, "TB Error: displays show %h but pc is %h",
                       displayed, dut.imem_addr[23:0]);
            end
            if (ledr[9:2] !== dut.imem_addr[9:2]) begin
                $fatal(1, "TB Error: LEDR shows %b but pc[9:2] is %b",
                       ledr[9:2], dut.imem_addr[9:2]);
            end
            if (ledr[1]) begin
                $fatal(1, "TB Error: memory error LED lit after %0d board cycles", cycles);
            end
            if (ledr[0]) begin
                $display("TB Info: halt LED lit after %0d board cycles (~%0d cpu cycles)",
                         cycles, cycles / 4);
                $finish;
            end
            if (cycles >= timeout) begin
                $fatal(1, "TB Error: timed out after %0d board cycles", cycles);
            end
            cycles <= cycles + 1;
        end
    end

endmodule
