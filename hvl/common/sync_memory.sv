// Synchronous-read memory model, for the pipelined core.
//
// Same ports and same checks as magic_memory.sv; the difference is that reads
// are registered, so data arrives one cycle after the address. That is what
// real memory does, and it is exactly what a pipeline wants: the IF stage's
// fetch lands at the start of ID, and the MEM stage's load lands at the start
// of WB. No stall is needed for either -- the pipeline registers absorb the
// latency that forced the single-cycle core to use a combinational read.
//
// Timing here matches fpga/mem_sync.sv, so a program that runs against this
// model behaves the same way on the board.

module sync_memory #(
    parameter bit [31:0]   MEM_BASE = 32'h8000_0000,
    parameter int unsigned MEM_SIZE = 32'h0001_0000
)(
    input  logic        clk,
    input  logic        rst,

    input  logic [31:0] imem_addr,
    output logic [31:0] imem_rdata,

    input  logic [31:0] dmem_addr,
    input  logic [31:0] dmem_wdata,
    input  logic [3:0]  dmem_rmask,
    input  logic [3:0]  dmem_wmask,
    output logic [31:0] dmem_rdata,

    output logic        error
);

    localparam int unsigned NUM_WORDS = MEM_SIZE / 4;
    localparam int unsigned IDX_BITS  = $clog2(NUM_WORDS);

    logic [31:0] ram [NUM_WORDS];

    string       memfile;
    logic [31:0] fill;

    initial begin
        fill = '0;
        void'($value$plusargs("MEM_FILL=%h", fill));
        for (int i = 0; i < int'(NUM_WORDS); i++) begin
            ram[i] = fill;
        end
        if (!$value$plusargs("MEMLST=%s", memfile)) begin
            $fatal(1, "TB Error: +MEMLST=<path> was not provided");
        end
        $readmemh(memfile, ram);
        $display("TB Info: sync memory %0d KiB at %h, gaps filled with %h",
                 MEM_SIZE / 1024, MEM_BASE, fill);
    end

    function automatic bit in_range(logic [31:0] addr);
        return (addr >= MEM_BASE) && (addr < MEM_BASE + 32'(MEM_SIZE));
    endfunction

    function automatic bit legal_mask(logic [3:0] mask);
        case (mask)
            4'b0000,
            4'b0001, 4'b0010, 4'b0100, 4'b1000,
            4'b0011, 4'b1100,
            4'b1111:  legal_mask = 1'b1;
            default:  legal_mask = 1'b0;
        endcase
    endfunction

    logic [IDX_BITS-1:0] imem_idx, dmem_idx;

    assign imem_idx = IDX_BITS'((imem_addr - MEM_BASE) >> 2);
    assign dmem_idx = IDX_BITS'((dmem_addr - MEM_BASE) >> 2);

    always_ff @(posedge clk) begin
        imem_rdata <= in_range(imem_addr) ? ram[imem_idx] : 'x;
    end

    always_ff @(posedge clk) begin
        dmem_rdata <= (dmem_rmask == '0)  ? '0
                    : in_range(dmem_addr) ? ram[dmem_idx]
                    :                       'x;
        for (int i = 0; i < 4; i++) begin
            if (dmem_wmask[i] && in_range(dmem_addr)) begin
                ram[dmem_idx][8*i +: 8] <= dmem_wdata[8*i +: 8];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            error <= 1'b0;
        end else begin
            if (imem_addr[1:0] != 2'b00) begin
                $display("TB Error: unaligned instruction fetch at %h", imem_addr);
                error <= 1'b1;
            end
            if (!in_range(imem_addr)) begin
                $display("TB Error: instruction fetch outside memory at %h", imem_addr);
                error <= 1'b1;
            end
            if (dmem_rmask != '0 || dmem_wmask != '0) begin
                if (dmem_addr[1:0] != 2'b00) begin
                    $display("TB Error: unaligned data access at %h", dmem_addr);
                    error <= 1'b1;
                end
                if (!in_range(dmem_addr)) begin
                    $display("TB Error: data access outside memory at %h", dmem_addr);
                    error <= 1'b1;
                end
                if (dmem_rmask != '0 && dmem_wmask != '0) begin
                    $display("TB Error: simultaneous read and write at %h", dmem_addr);
                    error <= 1'b1;
                end
                if (!legal_mask(dmem_rmask)) begin
                    $display("TB Error: illegal read mask %b at %h", dmem_rmask, dmem_addr);
                    error <= 1'b1;
                end
                if (!legal_mask(dmem_wmask)) begin
                    $display("TB Error: illegal write mask %b at %h", dmem_wmask, dmem_addr);
                    error <= 1'b1;
                end
            end
        end
    end

endmodule
