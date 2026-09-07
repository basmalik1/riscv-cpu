// Synthesizable memory for the FPGA build. Replaces hvl/common/magic_memory.sv,
// which is testbench-only (plusargs, $display, combinational reads).
//
// WHY THIS IS NOT JUST "magic_memory with a clock"
//
// FPGA block RAM registers its read output, so data appears one clock edge
// after the address. That alone would be fine for instruction fetch. The
// problem is the data port: dmem_addr comes out of the ALU, which needs
// imem_rdata first. Fetch and data access therefore cannot share an edge --
// the data address does not exist yet when the instruction arrives.
//
// So the two ports are served on different edges of a fast clock, and the CPU
// runs on a divided-down clock slow enough to contain both. This module just
// exposes a clock enable per port; fpga/top_de10lite.sv owns the phasing.
//
// Both ports index one array, so this stays a unified memory like the
// simulation model: loads from .rodata work, and a store is visible to a later
// fetch. On Intel parts this infers a true dual-port M9K.

module mem_sync #(
    parameter bit [31:0]   MEM_BASE  = 32'h8000_0000,
    parameter int unsigned MEM_SIZE  = 32'h0001_0000,
    parameter string       INIT_FILE = "memory_32.lst"
)(
    input  logic        clk,        // fast clock (board clock, undivided)
    input  logic        rst,

    // Instruction port: read only, captured when imem_en is high.
    input  logic        imem_en,
    input  logic [31:0] imem_addr,
    output logic [31:0] imem_rdata,

    // Data port: read and masked write, captured when dmem_en is high.
    input  logic        dmem_en,
    input  logic [31:0] dmem_addr,
    input  logic [31:0] dmem_wdata,
    input  logic [3:0]  dmem_rmask,
    input  logic [3:0]  dmem_wmask,
    output logic [31:0] dmem_rdata,

    // Sticky: an access left the modelled memory. Drives a board LED.
    output logic        error
);

    localparam int unsigned NUM_WORDS = MEM_SIZE / 4;
    localparam int unsigned IDX_BITS  = $clog2(NUM_WORDS);

    logic [31:0] ram [NUM_WORDS];

    // Both Quartus and Verilator honour $readmemh for inferred RAM
    // initialisation, which is what lets this module be simulated before it
    // ever reaches a board. If a Quartus version rejects it, generate a .mif
    // with bin/generate_memory_file.py --mif and swap this for a
    // (* ram_init_file = "memory.mif" *) attribute on ram.
    initial begin
        $readmemh(INIT_FILE, ram);
    end

    logic [IDX_BITS-1:0] imem_idx, dmem_idx;
    logic                imem_ok, dmem_ok;

    // Explicit truncation: the subtract and shift are 32-bit, the index is not.
    // The range checks below are what make discarding the high bits safe.
    assign imem_idx = IDX_BITS'((imem_addr - MEM_BASE) >> 2);
    assign dmem_idx = IDX_BITS'((dmem_addr - MEM_BASE) >> 2);

    assign imem_ok = (imem_addr >= MEM_BASE) && (imem_addr < MEM_BASE + 32'(MEM_SIZE));
    assign dmem_ok = (dmem_addr >= MEM_BASE) && (dmem_addr < MEM_BASE + 32'(MEM_SIZE));

    always_ff @(posedge clk) begin
        if (imem_en) begin
            imem_rdata <= ram[imem_idx];
        end
    end

    always_ff @(posedge clk) begin
        if (dmem_en) begin
            dmem_rdata <= ram[dmem_idx];
            for (int i = 0; i < 4; i++) begin
                if (dmem_wmask[i]) begin
                    ram[dmem_idx][8*i +: 8] <= dmem_wdata[8*i +: 8];
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            error <= 1'b0;
        end else begin
            if (imem_en && !imem_ok) begin
                error <= 1'b1;
            end
            if (dmem_en && (dmem_rmask != '0 || dmem_wmask != '0) && !dmem_ok) begin
                error <= 1'b1;
            end
        end
    end

endmodule
