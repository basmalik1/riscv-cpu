// DE10-Lite top level for the pipelined core.
//
// Considerably simpler than the single-cycle one, and that is the point of the
// iteration rather than a coincidence.
//
// The single-cycle top needs a phase counter dividing the board clock by four,
// because block RAM registers its read output and dmem_addr depends on
// imem_rdata -- so one instruction needs two memory edges and the core has to
// run at 12.5 MHz. A pipeline has no such problem: IF and MEM are different
// instructions in the same cycle, so both memory ports are simply enabled every
// cycle and the core runs directly on the 50 MHz board clock.
//
// That also removes the counter-bit-as-clock that Quartus rightly complains
// about in the single-cycle build. There is no derived clock here at all.

module top_de10lite #(
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
    // core and memory
    // ------------------------------------------------------------------
    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_rmask, dmem_wmask;
    logic        mem_error, core_halt, core_commit;

    cpu #(
        .RESET_PC   (MEM_BASE)
    ) core (
        .clk        (clk),
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

    // Both ports enabled unconditionally. IF and MEM hold different
    // instructions, so there is nothing to arbitrate between them.
    mem_sync #(
        .MEM_BASE   (MEM_BASE),
        .MEM_SIZE   (MEM_SIZE)
    ) mem (
        .clk        (clk),
        .rst        (rst),
        .imem_en    (1'b1),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_en    (1'b1),
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
    logic halted;

    always_ff @(posedge clk) begin
        if (rst) begin
            halted <= 1'b0;
        end else if (core_halt) begin
            halted <= 1'b1;
        end
    end

    // The displays are sampled slowly rather than driven live. A failing test
    // spins on `j fail`, and this core redirects on every pass through it, so
    // the fetch PC cycles over the jump and the two instructions squashed
    // behind it. At 50 MHz that is an unreadable blur. Sampling lands on one of
    // those three, which is within 8 bytes of the fail loop -- close enough to
    // find in sim/bin/<prog>.dis, which is what the display is for.
    logic [23:0] sample_count;
    logic [23:0] hex_value;

    always_ff @(posedge clk) begin
        if (rst) begin
            sample_count <= '0;
            hex_value    <= '0;
        end else begin
            sample_count <= sample_count + 24'd1;
            if (sample_count == '0) begin
                hex_value <= imem_addr[23:0];
            end
        end
    end

    seven_seg d0 (.value(hex_value[3:0]),   .seg(HEX0));
    seven_seg d1 (.value(hex_value[7:4]),   .seg(HEX1));
    seven_seg d2 (.value(hex_value[11:8]),  .seg(HEX2));
    seven_seg d3 (.value(hex_value[15:12]), .seg(HEX3));
    seven_seg d4 (.value(hex_value[19:16]), .seg(HEX4));
    seven_seg d5 (.value(hex_value[23:20]), .seg(HEX5));

    assign LEDR[0]   = halted;
    assign LEDR[1]   = mem_error;
    assign LEDR[9:2] = imem_addr[9:2];

    // SW and KEY1 are unused for now; read them so lint does not flag the pins
    // and the assignments stay valid for later use.
    logic unused_in;
    assign unused_in = |SW & KEY[1] & core_commit;

endmodule
