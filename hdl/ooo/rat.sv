// Register alias table: which physical register currently holds each
// architectural one.
//
// Instantiated twice by the finished core, which is why it is one module and
// not two. The speculative copy is written at rename and is what in-flight
// instructions read; the retirement copy is written at commit and is therefore
// always the architectural truth, which is what makes it the thing to restore
// from after a mispredict. Nothing about the table itself differs between the
// two -- only what drives `we`.
//
// Reads are READ-FIRST, and deliberately the opposite of what regfile.sv does
// for the pipelined core. There, WRITE_FIRST exists so a value written by WB is
// visible to an instruction decoding in the same cycle. Here the write and the
// reads in a cycle belong to the SAME instruction, and an instruction's sources
// are renamed against the mapping that existed before its own destination was
// renamed. `add x1, x1, x2` has to read the old x1 and write a new one; a
// write-first table would hand it the tag it is about to define and produce an
// instruction that depends on itself.
//
// x0 is never remapped. Writes to entry 0 are dropped, so it keeps its reset
// mapping to physical register 0 forever, and reads of x0 always return that
// tag. Making x0 read as the VALUE zero is then the physical register file's
// job, not this table's -- see prf.sv when it exists. Rename is expected to
// avoid allocating a tag for an instruction whose destination is x0 at all;
// the guard here is what makes that safe rather than merely conventional.
//
// RESTORE, which the reorder buffer forced the shape of. After a mispredict the
// speculative table has to become the retirement one again, and there are two
// ways to get there. Undoing each squashed rename in turn is tempting because
// the reorder buffer is already walking those entries -- but it only works
// walking YOUNGEST FIRST, and that walk runs oldest first, so a register
// renamed twice would be restored to the middle mapping rather than the
// original. Copying the whole table in one cycle avoids the ordering question
// entirely, at the price of a 192-bit bus between the two instances.

module rat #(
    parameter int unsigned PHYS_REGS = 64,
    parameter int unsigned ARCH_REGS = 32
)(
    input  logic clk,
    input  logic rst,

    // Source lookups for the instruction being renamed.
    input  logic [$clog2(ARCH_REGS)-1:0] rs1_addr,
    input  logic [$clog2(ARCH_REGS)-1:0] rs2_addr,
    output logic [$clog2(PHYS_REGS)-1:0] rs1_tag,
    output logic [$clog2(PHYS_REGS)-1:0] rs2_tag,

    // The new mapping for this instruction's destination.
    input  logic                         we,
    input  logic [$clog2(ARCH_REGS)-1:0] rd_addr,
    input  logic [$clog2(PHYS_REGS)-1:0] rd_tag,

    // The mapping being displaced, read before the write lands. The reorder
    // buffer has to carry this so commit knows which tag to release: the tag
    // an instruction frees is the one its destination pointed at BEFORE it,
    // never its own, because its own is what the architectural state becomes.
    output logic [$clog2(PHYS_REGS)-1:0] rd_old_tag,

    // The whole table, for the copy described above. The retirement instance
    // drives this; the speculative one takes it back through restore.
    output logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] map_out,

    // Held for the whole flush rather than pulsed. The retirement table cannot
    // move during a squash walk -- nothing commits while one is running -- so
    // copying it on every cycle of the walk is the same as copying it once,
    // and needs no edge to be caught.
    input  logic                                       restore,
    input  logic [ARCH_REGS-1:0][$clog2(PHYS_REGS)-1:0] restore_map
);

    localparam int unsigned ARCH_BITS = $clog2(ARCH_REGS);
    localparam int unsigned PHYS_BITS = $clog2(PHYS_REGS);

    // Packed, so the whole table is one value that can be copied in a cycle.
    logic [ARCH_REGS-1:0][PHYS_BITS-1:0] map;

    assign map_out = map;

    // All three reads see the state before this cycle's write.
    assign rs1_tag    = map[rs1_addr];
    assign rs2_tag    = map[rs2_addr];
    assign rd_old_tag = map[rd_addr];

    always_ff @(posedge clk) begin
        if (rst) begin
            // Architectural register i starts in physical register i, which is
            // the assumption the free list is built on: it comes up holding
            // exactly the tags from ARCH_REGS upward, so the two agree about
            // who owns what without either having to be told.
            for (int i = 0; i < int'(ARCH_REGS); i++) begin
                map[i] <= PHYS_BITS'(unsigned'(i));
            end
        end else if (restore) begin
            // Ahead of the write on purpose. A rename in the cycle a flush
            // starts belongs to an instruction being squashed, so applying it
            // over the restored table would reintroduce exactly the mapping
            // the restore exists to remove.
            map <= restore_map;
        end else if (we && (rd_addr != {ARCH_BITS{1'b0}})) begin
            map[rd_addr] <= rd_tag;
        end
    end

endmodule
