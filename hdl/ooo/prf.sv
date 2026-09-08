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

    // Value reads, for execute. It never asks whether a register is ready --
    // the issue queue has already established that, which is the only reason
    // the instruction was issued at all.
    input  logic [$clog2(PHYS_REGS)-1:0] rs1_tag,
    output logic [31:0]                  rs1_value,
    input  logic [$clog2(PHYS_REGS)-1:0] rs2_tag,
    output logic [31:0]                  rs2_value,

    // Readiness lookups, for dispatch. Separate ports because dispatch asks
    // about DIFFERENT registers than execute is reading in the same cycle: one
    // instruction is being renamed while another issues. Cheap to add --
    // selecting one bit of a 64-bit vector is nothing beside muxing 32 bits out
    // of 64 registers, which is what a value port costs.
    input  logic [$clog2(PHYS_REGS)-1:0] chk1_tag,
    output logic                         chk1_ready,
    input  logic [$clog2(PHYS_REGS)-1:0] chk2_tag,
    output logic                         chk2_ready,

    // A third value read, for the commit trace and nothing else. At commit the
    // result is in the register file and nowhere else, so reporting what an
    // instruction produced means reading it back.
    //
    // This is the one place the out-of-order core pays real hardware for
    // verification, and it is a whole 32-bit read port rather than the handful
    // of wires the other two cores needed. The alternative -- reconstructing
    // the value in the testbench from the result bus -- would report the value
    // the bus CARRIED rather than the one the register file HOLDS, so a
    // register file that failed to store would trace correctly and lockstep
    // would pass on a real bug.
    input  logic [$clog2(PHYS_REGS)-1:0] commit_tag,
    output logic [31:0]                  commit_value,

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
    assign rs1_value    = (rs1_tag    == '0) ? 32'd0 : data[rs1_tag];
    assign rs2_value    = (rs2_tag    == '0) ? 32'd0 : data[rs2_tag];
    assign commit_value = (commit_tag == '0) ? 32'd0 : data[commit_tag];

    assign chk1_ready = (chk1_tag == '0) ? 1'b1 : ready[chk1_tag];
    assign chk2_ready = (chk2_tag == '0) ? 1'b1 : ready[chk2_tag];

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
