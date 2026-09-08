// The pool of physical registers not currently owned by an architectural one.
//
// Rename takes a tag from here for every instruction that writes a register.
// Commit gives back the tag that the committing instruction displaced -- the
// PREVIOUS mapping of its destination, not its own, since its own is what the
// architectural state now is.
//
// Thin on purpose. It is a fifo with domain names on the ports and one sizing
// rule fixed in one place; if this file were doing real work, the queue
// underneath it would be the wrong shape.
//
// Sizing. Architectural register i starts mapped to physical register i, so the
// pool comes up holding tags ARCH_REGS through PHYS_REGS-1. The natural choice
// for PHYS_REGS is ARCH_REGS plus the reorder buffer depth: every in-flight
// instruction can hold at most one tag, so a pool that size can never be the
// reason rename stalls. Both of those must leave a power-of-two depth, which is
// what fifo requires and does not check.
//
// NOT here yet: recovery. On a mispredict the tags held by squashed
// instructions have to come back, and there is no honest way to design that
// before the reorder buffer and the retirement map exist -- the two candidate
// answers (roll the allocation pointer back to the last committed point, or
// rebuild the pool from the retirement map) make different demands on both.
// Resetting this module on a flush would be actively wrong: it would hand back
// tags the architectural state still owns. So there is deliberately no flush
// input rather than a plausible-looking one.

module free_list #(
    parameter int unsigned PHYS_REGS = 64,
    parameter int unsigned ARCH_REGS = 32
)(
    input  logic clk,
    input  logic rst,

    // Rename side. alloc_tag is meaningful only while alloc_valid is high;
    // asserting alloc without it is ignored rather than trapped, and rename is
    // expected to have stalled instead.
    input  logic                          alloc,
    output logic [$clog2(PHYS_REGS)-1:0]  alloc_tag,
    output logic                          alloc_valid,

    // Commit side.
    input  logic                          free,
    input  logic [$clog2(PHYS_REGS)-1:0]  free_tag,

    // Every tag is free. True at reset and whenever the machine has drained,
    // so not an error in itself -- but a `free` asserted while it is high is a
    // tag being returned that nobody holds, and the queue underneath will drop
    // it silently. tb_free_list checks that never happens; nothing in hardware
    // traps it.
    output logic                          full,

    // How many tags are available. Exposed because a leak is otherwise
    // invisible until the pool runs dry, which could be thousands of
    // instructions after the mistake.
    output logic [$clog2(PHYS_REGS - ARCH_REGS):0] count
);

    localparam int unsigned PHYS_BITS = $clog2(PHYS_REGS);
    localparam int unsigned DEPTH     = PHYS_REGS - ARCH_REGS;

    logic pool_empty;

    fifo #(
        .WIDTH     (PHYS_BITS),
        .DEPTH     (DEPTH),
        .INIT_FULL (1'b1),
        .INIT_BASE (ARCH_REGS)
    ) pool (
        .clk       (clk),
        .rst       (rst),
        .push      (free),
        .push_data (free_tag),
        .pop       (alloc),
        .pop_data  (alloc_tag),
        .full      (full),
        .empty     (pool_empty),
        .count     (count)
    );

    assign alloc_valid = !pool_empty;

endmodule
