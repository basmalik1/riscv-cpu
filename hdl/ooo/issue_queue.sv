// Issue queue: holds dispatched instructions until their operands exist, then
// releases the oldest one that is ready.
//
// Holds tags, never values. An entry knows which physical registers it is
// waiting on and whether they have arrived; the values themselves are read out
// of prf.sv at issue. That is the same rule the whole design is built on -- a
// value has one home -- and it is what separates this from a Tomasulo
// reservation station, which captures a copy of every operand it sees.
//
// COMPACTING. On issue, every entry above the one leaving shifts down, so an
// entry's index is its age: entry 0 is the oldest instruction present.
// Selecting the oldest ready instruction is then a priority encoder over the
// ready bits, with no age matrix and no starvation. The cost is a shift
// network, one mux per entry, which at this depth is cheap and at a much wider
// one would not be.
//
// SELECTION READS THE REGISTERED STATE, NOT THIS CYCLE'S WAKEUP. An instruction
// whose operand is broadcast in cycle N becomes selectable in N+1, never in N.
// That is not conservatism, it is the only correct choice given how prf.sv
// behaves: the broadcast value does not land in the register file until the end
// of cycle N, so an instruction issued during N would read the previous
// contents. Selecting from the post-wakeup state instead would issue every
// dependent instruction exactly one cycle early and feed it stale data --
// invisible in this module, and wrong everywhere downstream.
//
// Wakeup is an OR across every broadcast port, computed in one place. Writing
// it as a loop that assigns the ready bit per port makes the last port win
// rather than any port, so an entry woken by port 0 goes back to sleep when
// port 1 does not match it.

module issue_queue #(
    parameter int unsigned DEPTH      = 8,
    parameter int unsigned PHYS_REGS  = 64,
    parameter int unsigned PAYLOAD_W  = 64,

    // How many results can be broadcast in one cycle. One is enough while a
    // single functional unit can complete per cycle; more than one costs a
    // comparator per port per entry.
    parameter int unsigned NUM_WAKEUP = 1
)(
    input  logic clk,
    input  logic rst,

    // ---------------- dispatch ----------------
    // Ready bits come from prf.sv at dispatch and are maintained here
    // afterwards. Physical register 0 always reads ready there, so an
    // instruction with no second source needs no special case.
    input  logic                          dispatch,
    input  logic [$clog2(PHYS_REGS)-1:0]  dispatch_rs1,
    input  logic                          dispatch_rs1_ready,
    input  logic [$clog2(PHYS_REGS)-1:0]  dispatch_rs2,
    input  logic                          dispatch_rs2_ready,
    input  logic [PAYLOAD_W-1:0]          dispatch_payload,
    output logic                          dispatch_ready,

    // ---------------- wakeup ----------------
    input  logic [NUM_WAKEUP-1:0]                        wake_valid,
    input  logic [NUM_WAKEUP-1:0][$clog2(PHYS_REGS)-1:0] wake_tag,

    // ---------------- issue ----------------
    // A handshake, because a functional unit can be busy -- a divide occupies
    // the multiply/divide unit for tens of cycles, and the queue must hold the
    // instruction rather than drop it.
    output logic                          issue_valid,
    output logic [PAYLOAD_W-1:0]          issue_payload,
    input  logic                          issue_accept,

    // Driven by the reorder buffer. Everything here is speculative by
    // definition, so a flush simply empties it -- there is nothing to hand
    // back, since the physical registers these entries hold are released by
    // the reorder buffer's own squash walk.
    input  logic                          flush,

    output logic [$clog2(DEPTH):0]        count
);

    localparam int unsigned PB  = $clog2(PHYS_REGS);
    localparam int unsigned CB  = $clog2(DEPTH);

    typedef struct packed {
        logic                 valid;
        logic [PB-1:0]        rs1;
        logic                 rs1_ready;
        logic [PB-1:0]        rs2;
        logic                 rs2_ready;
        logic [PAYLOAD_W-1:0] payload;
    } iq_entry_t;

    iq_entry_t entries [DEPTH];
    logic [CB:0] occupancy;

    assign count          = occupancy;
    assign dispatch_ready = (occupancy < (CB+1)'(DEPTH)) && !flush;

    // ------------------------------------------------------------------
    // wakeup: any port, not the last port
    // ------------------------------------------------------------------
    function automatic logic woken_by(logic [PB-1:0] tag);
        woken_by = 1'b0;
        for (int j = 0; j < int'(NUM_WAKEUP); j++) begin
            if (wake_valid[j] && (wake_tag[j] == tag)) begin
                woken_by = 1'b1;
            end
        end
    endfunction

    iq_entry_t woken [DEPTH];

    always_comb begin
        for (int i = 0; i < int'(DEPTH); i++) begin
            woken[i]           = entries[i];
            woken[i].rs1_ready = entries[i].rs1_ready || woken_by(entries[i].rs1);
            woken[i].rs2_ready = entries[i].rs2_ready || woken_by(entries[i].rs2);
        end
    end

    // ------------------------------------------------------------------
    // select: the oldest ready entry, from the REGISTERED state
    // ------------------------------------------------------------------
    // entries, not woken. See the note at the top: an entry woken this cycle
    // is selectable next cycle, because the value it is waiting for does not
    // reach the register file until this cycle ends.
    logic [CB-1:0] issue_idx;

    always_comb begin
        issue_idx   = '0;
        issue_valid = 1'b0;
        // Descending, so the lowest matching index -- the oldest instruction --
        // is the one left assigned.
        for (int i = int'(DEPTH) - 1; i >= 0; i--) begin
            if (entries[i].valid && entries[i].rs1_ready && entries[i].rs2_ready) begin
                issue_idx   = CB'(unsigned'(i));
                issue_valid = 1'b1;
            end
        end
    end

    assign issue_payload = entries[issue_idx].payload;

    logic taking;
    assign taking = issue_valid && issue_accept;

    // ------------------------------------------------------------------
    iq_entry_t next [DEPTH];
    logic [CB:0] next_occupancy;

    always_comb begin
        next           = woken;
        next_occupancy = occupancy;

        // Collapse over the entry being issued.
        if (taking) begin
            for (int i = 0; i < int'(DEPTH) - 1; i++) begin
                if ((CB+1)'(unsigned'(i)) >= {1'b0, issue_idx}) begin
                    next[i] = woken[i + 1];
                end
            end
            next[DEPTH-1] = '0;
            next_occupancy = occupancy - 1'b1;
        end

        // The new entry goes on the end, which after any collapse above is the
        // first free slot and also the youngest position.
        if (dispatch && dispatch_ready) begin
            next[next_occupancy[CB-1:0]] = '{
                valid:     1'b1,
                rs1:       dispatch_rs1,
                // Woken in the same cycle it is dispatched, if the broadcast
                // names one of its sources. Without this an instruction
                // dispatched on the exact cycle its operand arrives waits
                // forever, because the broadcast is gone by the next one.
                rs1_ready: dispatch_rs1_ready || woken_by(dispatch_rs1),
                rs2:       dispatch_rs2,
                rs2_ready: dispatch_rs2_ready || woken_by(dispatch_rs2),
                payload:   dispatch_payload
            };
            next_occupancy = next_occupancy + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            for (int i = 0; i < int'(DEPTH); i++) begin
                entries[i] <= '0;
            end
            occupancy <= '0;
        end else begin
            entries   <= next;
            occupancy <= next_occupancy;
        end
    end

endmodule
