// Reorder buffer: what makes out-of-order execution look in-order from outside.
//
// Holds bookkeeping and no data. Values live in prf.sv and nowhere else, which
// is the whole point of renaming explicitly; an entry here records only what
// commit needs to know in order to make an instruction's effects architectural,
// or to undo them.
//
// Not a fifo, despite the pointer arithmetic looking identical. A fifo is
// written at the tail and read at the head; this is written at an ARBITRARY
// entry, because a functional unit completes whichever instruction it was given
// and marks that one done. Random access is the difference, and it is why this
// keeps its own head and tail rather than instantiating fifo.sv.
//
// Three things happen to an entry, in this order:
//
//   allocate   Rename takes the tail slot. Its index becomes the tag the
//              functional unit will report back with. The entry records the
//              physical register the instruction took, the one it displaced,
//              and enough to rebuild architectural state.
//
//   complete   Execution finished. Sets done, and for a branch records whether
//              the prediction was wrong and where to resume.
//
//   commit     The entry reaches the head and is done, so its effects become
//              architectural: the retirement map takes rd_phys, and rd_old_phys
//              -- the register this instruction DISPLACED -- goes back to the
//              free list. Its own tag does not: that register now holds
//              architectural state.
//
// Recovery is the mirror of that last rule. A squashed instruction never became
// architectural, so it releases its OWN tag rather than the one it displaced.
// After a mispredicting instruction commits, this walks the entries behind it
// and hands each one's rd_phys back, one per cycle, which is what `squash_free`
// is for. That costs a cycle per in-flight instruction, and it is the reason
// free_list and rat needed no flush port of their own -- the ROB drives their
// ordinary ones.

module rob #(
    parameter int unsigned DEPTH     = 32,
    parameter int unsigned PHYS_REGS = 64,
    parameter int unsigned ARCH_REGS = 32
)(
    input  logic clk,
    input  logic rst,

    // ---------------- allocate, from rename ----------------
    input  logic                          alloc,
    input  logic [$clog2(ARCH_REGS)-1:0]  alloc_rd_arch,
    input  logic [$clog2(PHYS_REGS)-1:0]  alloc_rd_phys,
    input  logic [$clog2(PHYS_REGS)-1:0]  alloc_rd_old_phys,
    input  logic                          alloc_writes_reg,
    input  logic [31:0]                   alloc_pc,
    input  logic                          alloc_is_halt,

    // The slot taken, which is the tag execution reports back with.
    output logic [$clog2(DEPTH)-1:0]      alloc_idx,
    // Low when the buffer is full or a flush is in progress. Rename stalls.
    output logic                          alloc_ready,

    // ---------------- complete, from writeback ----------------
    input  logic                          complete,
    input  logic [$clog2(DEPTH)-1:0]      complete_idx,
    input  logic                          complete_mispredict,
    input  logic [31:0]                   complete_redirect_pc,

    // ---------------- commit ----------------
    output logic                          commit,
    output logic [$clog2(ARCH_REGS)-1:0]  commit_rd_arch,
    output logic [$clog2(PHYS_REGS)-1:0]  commit_rd_phys,
    output logic                          commit_writes_reg,
    output logic [31:0]                   commit_pc,
    output logic                          commit_halt,

    // ---------------- recovery ----------------
    // High for the whole squash walk, one cycle after the mispredicting
    // instruction commits. Everything in front of the ROB discards its state
    // and resumes at flush_pc.
    output logic                          flush,
    output logic [31:0]                   flush_pc,

    // The free-list return port, shared by both directions. On a commit it
    // carries the DISPLACED register; during a squash walk it carries the
    // squashed instruction's OWN register.
    output logic                          free_valid,
    output logic [$clog2(PHYS_REGS)-1:0]  free_phys,

    output logic                          empty,
    output logic                          full
);

    localparam int unsigned IDX  = $clog2(DEPTH);
    localparam int unsigned PB   = $clog2(PHYS_REGS);
    localparam int unsigned AB   = $clog2(ARCH_REGS);

    typedef struct packed {
        logic          done;
        logic          writes_reg;
        logic          mispredict;
        logic          is_halt;
        logic [AB-1:0] rd_arch;
        logic [PB-1:0] rd_phys;
        logic [PB-1:0] rd_old_phys;
        logic [31:0]   pc;
        // Only the oldest mispredicting entry's copy is ever used, but which
        // entry that is cannot be known until it reaches the head, so every
        // entry carries one. This is the widest field here and the honest cost
        // of resolving branches at commit rather than at execute.
        logic [31:0]   redirect_pc;
    } rob_entry_t;

    rob_entry_t entries [DEPTH];

    // One bit wider than an index, so full and empty are distinguishable. Same
    // idiom as fifo.sv, and the only thing the two structures share.
    logic [IDX:0] head, tail;

    logic flushing;

    assign empty = (head == tail);
    assign full  = (head[IDX] != tail[IDX]) && (head[IDX-1:0] == tail[IDX-1:0]);

    assign alloc_idx   = tail[IDX-1:0];
    assign alloc_ready = !full && !flushing;

    rob_entry_t head_entry;
    assign head_entry = entries[head[IDX-1:0]];

    // An instruction commits when it reaches the head and has finished. Held
    // low during a flush: the walk is discarding entries, not retiring them.
    assign commit            = !empty && head_entry.done && !flushing;
    assign commit_rd_arch    = head_entry.rd_arch;
    assign commit_rd_phys    = head_entry.rd_phys;
    assign commit_writes_reg = head_entry.writes_reg;
    assign commit_pc         = head_entry.pc;
    assign commit_halt       = head_entry.is_halt;

    assign flush = flushing;

    // The one free-list port, driven from opposite ends of the entry depending
    // on which is happening. Committing releases what this instruction
    // displaced; squashing releases what it took.
    always_comb begin
        if (flushing) begin
            free_valid = !empty && head_entry.writes_reg;
            free_phys  = head_entry.rd_phys;
        end else begin
            free_valid = commit && head_entry.writes_reg;
            free_phys  = head_entry.rd_old_phys;
        end
    end

    logic [31:0] flush_pc_q;
    assign flush_pc = flush_pc_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            head       <= '0;
            tail       <= '0;
            flushing   <= 1'b0;
            flush_pc_q <= '0;
            for (int i = 0; i < int'(DEPTH); i++) begin
                entries[i] <= '0;
            end
        end else begin
            // ---- allocate ----
            if (alloc && alloc_ready) begin
                entries[tail[IDX-1:0]] <= '{
                    done:        1'b0,
                    writes_reg:  alloc_writes_reg,
                    mispredict:  1'b0,
                    is_halt:     alloc_is_halt,
                    rd_arch:     alloc_rd_arch,
                    rd_phys:     alloc_rd_phys,
                    rd_old_phys: alloc_rd_old_phys,
                    pc:          alloc_pc,
                    redirect_pc: 32'd0
                };
                tail <= tail + 1'b1;
            end

            // ---- complete ----
            // Allowed during a flush and harmless there: the entry it names is
            // either already behind the walk or about to be discarded by it.
            if (complete) begin
                entries[complete_idx].done        <= 1'b1;
                entries[complete_idx].mispredict  <= complete_mispredict;
                entries[complete_idx].redirect_pc <= complete_redirect_pc;
            end

            // ---- commit, and the walk that may follow ----
            if (flushing) begin
                if (empty) begin
                    flushing <= 1'b0;
                end else begin
                    head <= head + 1'b1;
                end
            end else if (commit) begin
                head <= head + 1'b1;
                // The mispredicting instruction itself commits normally -- its
                // own result is architectural. Only what came after it is
                // wrong, so the walk starts on the next cycle.
                if (head_entry.mispredict) begin
                    flushing   <= 1'b1;
                    flush_pc_q <= head_entry.redirect_pc;
                end
            end
        end
    end

endmodule
