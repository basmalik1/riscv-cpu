// Physical register file: where every value in the machine lives.
//
// The point of explicit register renaming is that a value has exactly one
// home. This is it. The reorder buffer holds bookkeeping and no data, the
// issue queue holds tags and no data, and nothing anywhere keeps a second copy
// that could disagree with this one.
//
// Each register carries a ready bit alongside its value, and the two move in
// opposite directions at different times. Rename ALLOCATES a tag, which clears
// ready: the register now belongs to an instruction that has not executed, so
// whatever bits are in it are stale. Writeback SETS ready and delivers the
// value. An instruction is issuable exactly when both its sources read ready.
//
// No read bypass, deliberately. An instruction whose source is broadcast this
// cycle is woken this cycle and issues the NEXT one, by which time the write
// below has landed on a clock edge and an ordinary read returns it. Bypassing
// would only buy something if wakeup and issue happened in the same cycle,
// which is a later optimisation and a much longer critical path.
//
// Physical register 0 is special and stays that way. rat.sv maps architectural
// x0 to it permanently and never remaps it, so reads of tag 0 must return zero
// and must always be ready. That is enforced here rather than assumed: the
// free list never hands out tag 0 and rename never allocates for a destination
// of x0, so in a correct machine the guard below never fires -- but it is what
// makes those two facts a belt rather than the only thing holding x0 up.

module prf #(
    parameter int unsigned PHYS_REGS = 64
)(
    input  logic clk,
    input  logic rst,

    input  logic [$clog2(PHYS_REGS)-1:0] rs1_tag,
    output logic [31:0]                  rs1_value,
    output logic                         rs1_ready,

    input  logic [$clog2(PHYS_REGS)-1:0] rs2_tag,
    output logic [31:0]                  rs2_value,
    output logic                         rs2_ready,

    // Rename: this tag now belongs to an instruction that has not run yet.
    input  logic                         alloc,
    input  logic [$clog2(PHYS_REGS)-1:0] alloc_tag,

    // Writeback: a functional unit produced a result.
    input  logic                         wb,
    input  logic [$clog2(PHYS_REGS)-1:0] wb_tag,
    input  logic [31:0]                  wb_value
);

    logic [31:0]          data  [PHYS_REGS];
    logic [PHYS_REGS-1:0] ready;

    // Reads see the state before this cycle's write, which is what "no bypass"
    // means in practice.
    assign rs1_value = (rs1_tag == '0) ? 32'd0 : data[rs1_tag];
    assign rs1_ready = (rs1_tag == '0) ? 1'b1  : ready[rs1_tag];
    assign rs2_value = (rs2_tag == '0) ? 32'd0 : data[rs2_tag];
    assign rs2_ready = (rs2_tag == '0) ? 1'b1  : ready[rs2_tag];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < int'(PHYS_REGS); i++) begin
                data[i] <= 32'd0;
            end
            // Everything reads ready out of reset. The low tags hold the
            // architectural registers, which are genuinely valid; the high
            // ones are in the free list and nothing will read them until
            // rename allocates one, which is the moment ready is cleared.
            ready <= '1;
        end else begin
            if (alloc) begin
                ready[alloc_tag] <= 1'b0;
            end
            // Ordered after the allocate on purpose. The two cannot target the
            // same tag in a correct machine -- a tag is allocated at rename and
            // written at execute, which are different cycles for the same
            // instruction -- but if they ever did, having the value and its
            // ready bit agree is the safer of the two outcomes.
            if (wb) begin
                data[wb_tag]  <= wb_value;
                ready[wb_tag] <= 1'b1;
            end
        end
    end

endmodule
