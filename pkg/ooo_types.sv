// Types used only by the out-of-order core. Kept out of pkg/types.sv so the
// other two builds do not carry structures they have no concept of, the same
// split pipelined_types.sv already uses.
//
// Deliberately created late. Every structure so far was parameterised and
// self-contained, so nothing needed a shared type until integration -- and a
// package written before anything crosses a module boundary is a guess about
// what the boundary will look like.

package ooo_types;

    import rv32i_types::*;

    // Sizing, in one place because these three numbers have to agree.
    //
    // PHYS_REGS is ARCH_REGS plus ROB_DEPTH: every in-flight instruction can
    // hold at most one physical register, so a pool that size means the free
    // list is never the reason rename stalls -- the reorder buffer fills first.
    // PHYS_REGS - ARCH_REGS must be a power of two, which is what fifo.sv
    // requires and does not check.
    //
    // The issue queue depth belongs here too and is not here yet: nothing
    // instantiates one until the top level does, and a constant declared
    // before it has a user is a guess.
    localparam int unsigned ROB_DEPTH  = 32;
    localparam int unsigned PHYS_REGS  = 64;

    localparam int unsigned PHYS_BITS  = $clog2(PHYS_REGS);   // 6
    localparam int unsigned ROB_BITS   = $clog2(ROB_DEPTH);   // 5

    // What an instruction carries from dispatch, through the issue queue, into
    // execute. The issue queue treats this as opaque bits and matches only on
    // the tags handed to it separately, so nothing here is visible to the
    // scheduling logic.
    typedef struct packed {
        logic [ROB_BITS-1:0]  rob_idx;

        // Where the result goes, and whether there is one. A store or a branch
        // allocates no physical register and writes_reg is low.
        logic [PHYS_BITS-1:0] rd_phys;
        logic                 writes_reg;

        // The operands to read from the register file at issue. The issue
        // queue holds its own copy of these for wakeup matching, but that copy
        // is internal to it -- carrying them here as well costs twelve bits an
        // entry and keeps that module unaware of what it is scheduling.
        logic [PHYS_BITS-1:0] rs1_phys;
        logic [PHYS_BITS-1:0] rs2_phys;

        logic [31:0]          pc;
        logic [31:0]          imm;

        alu_ops               aluop;
        alu_a_sel_t           alu_a_sel;
        alu_b_sel_t           alu_b_sel;
        wb_sel_t              wb_sel;
        logic [2:0]           funct3;

        logic                 is_branch;
        logic                 is_jal;
        logic                 is_jalr;
        logic                 is_muldiv;
        logic                 mem_read;
        logic                 mem_write;
        logic                 is_halt;
    } iq_payload_t;

endpackage
