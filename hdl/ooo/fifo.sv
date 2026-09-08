// A circular FIFO, parameterised by payload width and depth.
//
// The first thing built for the out-of-order core, because three of its
// structures are this module wearing different names: the free list is a FIFO
// of physical register tags, the instruction queue is a FIFO of fetched
// instructions, and the reorder buffer is this pointer arithmetic with a
// payload that can be written after it is enqueued.
//
// Getting it wrong once is therefore getting it wrong three times, which is
// the argument for building and testing it on its own before anything depends
// on it.
//
// Two constraints the parameters do not enforce, because there is no clean way
// to fail an elaboration in a module that also has to pass through sv2v and
// Yosys. tb_fifo covers both:
//
//   * DEPTH must be a power of two. The full/empty scheme below relies on the
//     pointer wrapping exactly at DEPTH, and a non-power-of-two silently
//     corrupts ordering rather than failing.
//   * DEPTH must be at least 2. At DEPTH 1 the index slice below is empty.

module fifo #(
    parameter int unsigned WIDTH = 32,
    parameter int unsigned DEPTH = 8,

    // Reset to FULL rather than empty, with entry i holding INIT_BASE + i.
    //
    // This exists for the free list, which comes up holding every physical
    // register that is not already committed to an architectural one. Writing
    // it here rather than in a free-list module of its own is what lets that
    // structure be an instantiation instead of a second copy of this pointer
    // arithmetic -- which is exactly the duplication this module exists to
    // avoid. Harmless when unused: INIT_FULL defaults off.
    parameter bit          INIT_FULL = 1'b0,
    parameter int unsigned INIT_BASE = 0
)(
    input  logic clk,
    input  logic rst,

    input  logic             push,
    input  logic [WIDTH-1:0] push_data,

    input  logic             pop,

    // The head, presented combinationally rather than after a pop. Every
    // consumer here needs to see the head in order to decide whether to pop it
    // -- the free list checks a tag is available, the ROB checks its oldest
    // entry is done -- so a registered read would cost a cycle in each of
    // them. Undefined while empty.
    output logic [WIDTH-1:0] pop_data,

    output logic full,
    output logic empty,

    // Occupancy, 0 to DEPTH inclusive, which is why it is one bit wider than
    // an index. Not needed by the FIFO itself; exposed because a free list
    // that has leaked tags is otherwise invisible until it runs dry.
    output logic [$clog2(DEPTH):0] count
);

    localparam int unsigned PTR = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [DEPTH];

    // One bit wider than an index. That extra bit is what separates full from
    // empty: both have head and tail agreeing on the index, and they differ
    // only in whether the pointers have wrapped a different number of times.
    logic [PTR:0] head, tail;

    assign empty = (head == tail);
    assign full  = (head[PTR] != tail[PTR]) && (head[PTR-1:0] == tail[PTR-1:0]);
    assign count = tail - head;

    assign pop_data = mem[head[PTR-1:0]];

    // A pop on an empty FIFO and a push on a full one are both ignored rather
    // than trapped -- the caller is expected to have looked. The one case
    // worth stating: pushing INTO a full FIFO while also popping it succeeds,
    // because the pop makes the room in the same cycle.
    logic do_push, do_pop;

    assign do_pop  = pop  && !empty;
    assign do_push = push && (!full || pop);

    always_ff @(posedge clk) begin
        if (rst) begin
            if (INIT_FULL) begin
                for (int i = 0; i < int'(DEPTH); i++) begin
                    mem[i] <= WIDTH'(INIT_BASE + unsigned'(i));
                end
                head <= '0;
                tail <= {1'b1, {PTR{1'b0}}};    // DEPTH, so full
            end else begin
                head <= '0;
                tail <= '0;
            end
        end else begin
            if (do_push) begin
                mem[tail[PTR-1:0]] <= push_data;
                tail <= tail + 1'b1;
            end
            if (do_pop) begin
                head <= head + 1'b1;
            end
        end
    end

endmodule
