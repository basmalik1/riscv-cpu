// DE10-Lite (MAX 10 10M50DAF484C7G) top level.
//
// TIMING, which is the whole reason this file exists
//
// Block RAM registers its read output and the data address depends on the
// fetched instruction, so one instruction needs two memory edges: one to
// return the instruction, a later one to return the load data. A 2-bit phase
// counter divides the 50 MHz board clock by four and hands each port its own
// edge:
//
//   phase 0  dmem_rdata is valid; writeback settles
//   phase 1  writeback still settling; cpu_clk is low
//   phase 2  cpu_clk rises here -- PC updates, imem_addr settles
//            imem_en asserted, so the edge ending this phase latches the fetch
//   phase 3  imem_rdata valid, ALU runs, dmem_addr settles
//            dmem_en asserted, so the edge ending this phase latches the data
//
// That gives the CPU 12.5 MHz from a 50 MHz board, with 20 ns for fetch-to-
// address and 40 ns for load-to-writeback. hdl/cpu.sv is untouched: from its
// point of view every instruction still completes in one of its own cycles.
//
// KNOWN SIMPLIFICATION: cpu_clk is a counter bit used as a clock. That is a
// derived clock, and Quartus will say so. It is fine for a demo at 12.5 MHz
// but the clean fix is to run everything on the 50 MHz clock and give cpu.sv a
// clock enable -- which the pipelined iteration wants anyway, since it needs
// stalls.

module top_de10lite #(
    // Parameters rather than localparams so the simulation build can override
    // them with -G. The defaults are what the board actually uses.
    parameter bit [31:0]   MEM_BASE = 32'h8000_0000,
    parameter int unsigned MEM_SIZE = 32'h0001_0000
)(
    input  logic        MAX10_CLK1_50,
    input  logic [1:0]  KEY,            // active low
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,
    output logic [7:0]  HEX0,
    output logic [7:0]  HEX1,
    output logic [7:0]  HEX2,
    output logic [7:0]  HEX3,
    output logic [7:0]  HEX4,
    output logic [7:0]  HEX5
);

    logic clk;
    logic rst;

    assign clk = MAX10_CLK1_50;
    assign rst = ~KEY[0];               // KEY0 held down = reset

    // ------------------------------------------------------------------
    // phase counter and derived CPU clock
    // ------------------------------------------------------------------
    logic [1:0] phase;
    logic       cpu_clk;

    // Deliberately free-running, with no reset. Holding the counter at zero
    // during reset would stop cpu_clk from ever rising, so the core would never
    // see the reset edge that loads RESET_PC into the PC -- it would come out of
    // reset fetching from address zero. Any starting phase is equally valid.
    always_ff @(posedge clk) begin
        phase <= phase + 2'd1;
    end

    assign cpu_clk = phase[1];          // rises on the 1 -> 2 transition

    // ------------------------------------------------------------------
    // core and memory
    // ------------------------------------------------------------------
    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_rmask, dmem_wmask;
    logic        mem_error;
    logic        core_halt;
    logic        core_commit;

    cpu #(
        .RESET_PC   (MEM_BASE)
    ) core (
        .clk        (cpu_clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_rmask (dmem_rmask),
        .dmem_wmask (dmem_wmask),
        .dmem_rdata (dmem_rdata),
        .halt       (core_halt),
        .commit     (core_commit)
    );

    mem_sync #(
        .MEM_BASE   (MEM_BASE),
        .MEM_SIZE   (MEM_SIZE)
    ) mem (
        .clk        (clk),
        .rst        (rst),
        .imem_en    (phase == 2'd2),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_en    (phase == 2'd3),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_rmask (dmem_rmask),
        .dmem_wmask (dmem_wmask),
        .dmem_rdata (dmem_rdata),
        .error      (mem_error)
    );

    // ------------------------------------------------------------------
    // observability -- there is no printf on a board
    // ------------------------------------------------------------------
    // The core reports its own halt, from a committed instruction rather than
    // the fetch bus. Latch it so the LED stays lit rather than flickering past.
    logic halted;

    always_ff @(posedge cpu_clk) begin
        if (rst) begin
            halted <= 1'b0;
        end else if (core_halt) begin
            halted <= 1'b1;
        end
    end

    // A failing test spins in its fail loop, so the PC stops moving and the
    // displays hold that address. Look it up in sim/bin/<prog>.dis to see which
    // check gave up.
    logic [23:0] hex_value;
    assign hex_value = imem_addr[23:0];

    seven_seg d0 (.value(hex_value[3:0]),   .seg(HEX0));
    seven_seg d1 (.value(hex_value[7:4]),   .seg(HEX1));
    seven_seg d2 (.value(hex_value[11:8]),  .seg(HEX2));
    seven_seg d3 (.value(hex_value[15:12]), .seg(HEX3));
    seven_seg d4 (.value(hex_value[19:16]), .seg(HEX4));
    seven_seg d5 (.value(hex_value[23:20]), .seg(HEX5));

    assign LEDR[0]   = halted;
    assign LEDR[1]   = mem_error;
    assign LEDR[9:2] = imem_addr[9:2];

    // SW is unused for now; tie it into the read so lint does not flag it and
    // the pin assignments stay valid for later use.
    logic unused_sw;
    assign unused_sw = |SW & KEY[1] & core_commit;

endmodule
