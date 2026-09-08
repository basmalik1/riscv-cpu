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
// NOT here yet: restore. Recovering the speculative table from the retirement
// one after a mispredict is the other half of flush, and the shape of that port
// depends on decisions the reorder buffer has not forced yet -- whether the
// copy happens in one cycle across a wide bus or is walked over several. Adding
// a plausible-looking one now would be guessing.

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
    output logic [$clog2(PHYS_REGS)-1:0] rd_old_tag
);

    localparam int unsigned ARCH_BITS = $clog2(ARCH_REGS);
    localparam int unsigned PHYS_BITS = $clog2(PHYS_REGS);

    logic [PHYS_BITS-1:0] map [ARCH_REGS];

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
        end else if (we && (rd_addr != {ARCH_BITS{1'b0}})) begin
            map[rd_addr] <= rd_tag;
        end
    end

endmodule
