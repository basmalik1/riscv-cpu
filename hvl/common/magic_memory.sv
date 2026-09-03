// Zero-latency behavioural memory backing both the instruction and data ports.
// Reads are combinational, writes land on the clock edge -- exactly what a
// single-cycle core needs, since fetch through writeback all happen inside one
// clock edge.
//
// This is NOT block RAM: FPGA BRAM registers its output and so costs a cycle of
// read latency. Nor is it a burst/DRAM timing model. Each iteration gets the
// simplest memory that makes its hazards real -- see docs/roadmap.md. The
// ready/resp handshake arrives with variable latency, not before.

// Access convention: dmem_addr is always word aligned. Byte lanes are selected
// entirely by dmem_rmask / dmem_wmask, so a byte or halfword access presents
// the containing word's address with a 1- or 2-bit mask and never a byte
// address. A consequence worth knowing: under this convention an illegal mask
// IS a misaligned access, so legal_mask() below is the only alignment check the
// data port needs.

module magic_memory #(
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

    // Reported failures are sticky and surfaced here; the testbench top decides
    // how the run ends. Deliberately $display rather than $error: Verilator
    // treats a procedural $error as an immediate assertion failure and stops
    // inside this block, which is both simulator-dependent and skips the
    // handshake below.
    output logic        error
);

    localparam int unsigned NUM_WORDS = MEM_SIZE / 4;

    logic [31:0] ram [NUM_WORDS];

    string       memfile;
    logic [31:0] fill;

    // Everything the program image does not cover -- .bss, the stack, any gap --
    // is left at `fill`. Zero by default, which keeps a runaway fetch decoding as
    // the all-zero illegal instruction rather than something that looks valid.
    //
    // Pass +MEM_FILL=<hex> to poison those gaps instead, which is what makes a
    // read-before-write visible: with zero fill a .bss or stack slot reads as 0
    // whether or not anything actually initialised it. Note the trade -- a poison
    // like deadbeef has 0x6f in its low byte, i.e. a JAL opcode, so a fetch into
    // a poisoned gap will jump rather than fault.
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
        $display("TB Info: memory %0d KiB at %h, gaps filled with %h",
                 MEM_SIZE / 1024, MEM_BASE, fill);
    end

    function automatic bit in_range(logic [31:0] addr);
        return (addr >= MEM_BASE) && (addr < MEM_BASE + 32'(MEM_SIZE));
    endfunction

    function automatic int unsigned word_index(logic [31:0] addr);
        return (addr - MEM_BASE) >> 2;
    endfunction

    // The only byte masks an RV32 load or store can produce: idle, one byte
    // anywhere, an aligned halfword, or the full word. Anything else -- 4'b0110
    // straddling the halfword boundary, or a non-contiguous 4'b0101 -- means the
    // load/store unit built the mask wrong.
    function automatic bit legal_mask(logic [3:0] mask);
        case (mask)
            4'b0000,                                        // no access
            4'b0001, 4'b0010, 4'b0100, 4'b1000,             // byte
            4'b0011, 4'b1100,                               // aligned halfword
            4'b1111:  legal_mask = 1'b1;                    // word
            default:  legal_mask = 1'b0;
        endcase
    endfunction

    assign imem_rdata = in_range(imem_addr) ? ram[word_index(imem_addr)] : 'x;
    assign dmem_rdata = (dmem_rmask == '0)  ? '0
                      : in_range(dmem_addr) ? ram[word_index(dmem_addr)]
                      :                       'x;

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

            for (int i = 0; i < 4; i++) begin
                if (dmem_wmask[i] && in_range(dmem_addr)) begin
                    ram[word_index(dmem_addr)][8*i +: 8] <= dmem_wdata[8*i +: 8];
                end
            end
        end
    end

endmodule
