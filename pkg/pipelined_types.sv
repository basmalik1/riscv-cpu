// Types used only by the pipelined core. Kept out of pkg/types.sv so the
// single-cycle build does not carry structures it has no concept of.
//
// Each struct is the payload of one pipeline register. Passing them whole
// rather than as loose signals is what keeps the stage port lists readable:
// adding a field to the datapath touches the struct and the two stages that
// care, not every module in between.

package pipelined_types;

    import rv32i_types::*;

    // Which forwarding source EX should use for an operand. The hazard unit
    // decides; stage_ex applies. Keeping the decision in one place is the
    // reason the hazard logic is auditable at all.
    typedef enum logic [1:0] {
        fwd_none = 2'b00,   // the value read in ID is current
        fwd_mem  = 2'b01,   // take it from the instruction in MEM
        fwd_wb   = 2'b10    // take it from the instruction in WB
    } fwd_sel_t;

    // IF/ID carries no instruction: the memory's own output register is that,
    // so this only has to remember which PC the in-flight fetch belongs to.
    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
    } if_id_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] imm;
        logic [31:0] rs1_v;
        logic [31:0] rs2_v;
        logic [4:0]  rs1_s;
        logic [4:0]  rs2_s;
        logic [4:0]  rd_s;
        logic [2:0]  funct3;
        alu_ops      aluop;
        alu_a_sel_t  alu_a_sel;
        alu_b_sel_t  alu_b_sel;
        wb_sel_t     wb_sel;
        logic        regf_we;
        logic        mem_read;
        logic        mem_write;
        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic        is_halt;
    } id_ex_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] alu_f;
        logic [31:0] pc4;
        logic [31:0] imm;
        logic [31:0] store_data;
        logic [4:0]  rd_s;
        logic [2:0]  funct3;
        wb_sel_t     wb_sel;
        logic        regf_we;
        logic        mem_read;
        logic        mem_write;
        logic        is_halt;
    } ex_mem_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] alu_f;
        logic [31:0] pc4;
        logic [31:0] imm;
        logic [1:0]  byte_off;
        logic [4:0]  rd_s;
        logic [2:0]  funct3;
        wb_sel_t     wb_sel;
        logic        regf_we;
        logic        is_halt;
    } mem_wb_t;

endpackage
