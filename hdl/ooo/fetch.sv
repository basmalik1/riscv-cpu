// Fetch: owns the program counter and presents one instruction to dispatch.
//
// There is no branch predictor, so this runs straight ahead and is corrected at
// commit. Every taken branch therefore costs a full flush, which is the single
// largest thing left on the table for this core and is deliberately not fixed
// here -- a predictor belongs in the iteration after this one, once there are
// IPC numbers to say what it would be worth.
//
// The awkward part is the same one the pipelined core hit, and it is worth
// stating plainly because holding the program counter looks like it should be
// enough. It is not. The memory read is synchronous, so the instruction
// arriving now belongs to the address presented LAST cycle. By the time
// dispatch says it cannot take that instruction, the address for the next one
// has already gone to memory, and next cycle the bus will carry the FOLLOWING
// instruction instead. Left alone that quietly drops one instruction per stall.
//
// So the instruction is captured on the first stalled cycle and replayed from
// here until dispatch takes it. The alternative -- not advancing the program
// counter -- cannot work, because the advance happened an edge too early to
// prevent.

module fetch #(
    parameter bit [31:0] RESET_PC = 32'h8000_0000
)(
    input  logic clk,
    input  logic rst,

    // Dispatch could not take what is being offered. Hold it.
    input  logic        stall,

    // From the reorder buffer, when a mispredicting instruction commits.
    input  logic        flush,
    input  logic [31:0] flush_pc,

    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    // The instruction on offer, the address it came from, and whether there is
    // one at all. `valid` is low out of reset and after a flush, for the cycle
    // it takes the redirected fetch to come back.
    output logic [31:0] inst,
    output logic [31:0] pc,
    output logic        valid
);

    // The address going to memory this cycle, and the address the instruction
    // coming BACK this cycle belongs to. They differ by one fetch, which is the
    // whole reason the second one has to exist.
    logic [31:0] pc_fetch;
    logic [31:0] pc_present;
    logic        valid_present;

    logic [31:0] held_inst;
    logic        held_valid;

    assign imem_addr = pc_fetch;
    assign pc        = pc_present;
    assign valid     = valid_present;
    assign inst      = held_valid ? held_inst : imem_rdata;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc_fetch      <= RESET_PC;
            pc_present    <= RESET_PC;
            valid_present <= 1'b0;
        end else if (flush) begin
            pc_fetch      <= flush_pc;
            pc_present    <= flush_pc;
            // Nothing valid until the redirected fetch returns, which is why
            // this is not simply held.
            valid_present <= 1'b0;
        end else if (!stall) begin
            pc_present    <= pc_fetch;
            pc_fetch      <= pc_fetch + 32'd4;
            valid_present <= 1'b1;
        end
    end

    // The flush term here is redundant, and deliberately kept. valid_present
    // only rises on the !stall branch above, and this block clears held_valid
    // on exactly that condition -- so by the time anything is offered as valid
    // again after a redirect, the held instruction has already been dropped by
    // the ordinary path. Mutation testing confirms it: removing `flush` from
    // this line changes no behaviour any test can observe.
    //
    // It stays because that argument depends on two separate always blocks
    // agreeing about when they fire. Anyone who changes the condition on
    // valid_present breaks the coupling silently, and this line is what keeps
    // a wrong-path instruction from surviving a redirect in that case.
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            held_valid <= 1'b0;
        end else if (stall && !held_valid) begin
            // First stalled cycle: the bus still carries the instruction
            // dispatch refused, so this is the last chance to keep it.
            held_inst  <= imem_rdata;
            held_valid <= 1'b1;
        end else if (!stall) begin
            held_valid <= 1'b0;
        end
    end

endmodule
