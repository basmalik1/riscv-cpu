package rv32i_types;

    localparam int unsigned XLEN      = 32;
    localparam int unsigned REG_COUNT = 32;
    localparam int unsigned REG_BITS  = 5;

    // Testbench traps this encoding (slti x0, x0, -256) to end the simulation.
    localparam logic [31:0] HALT_INST = 32'hf000_2013;

    typedef enum logic [6:0] {
        op_b_lui   = 7'b0110111, // load upper immediate           (U type)
        op_b_auipc = 7'b0010111, // add upper immediate to PC       (U type)
        op_b_jal   = 7'b1101111, // jump and link                   (J type)
        op_b_jalr  = 7'b1100111, // jump and link register          (I type)
        op_b_br    = 7'b1100011, // branch                          (B type)
        op_b_load  = 7'b0000011, // load                            (I type)
        op_b_store = 7'b0100011, // store                           (S type)
        op_b_imm   = 7'b0010011, // register/immediate arithmetic   (I type)
        op_b_reg   = 7'b0110011  // register/register arithmetic    (R type)
    } rv32i_opcode;

    typedef enum logic [2:0] {
        arith_f3_add  = 3'b000,  // funct7[5] selects sub for op_b_reg
        arith_f3_sll  = 3'b001,
        arith_f3_slt  = 3'b010,
        arith_f3_sltu = 3'b011,
        arith_f3_xor  = 3'b100,
        arith_f3_sr   = 3'b101,  // funct7[5] selects arithmetic shift
        arith_f3_or   = 3'b110,
        arith_f3_and  = 3'b111
    } arith_f3_t;

    typedef enum logic [2:0] {
        load_f3_lb  = 3'b000,
        load_f3_lh  = 3'b001,
        load_f3_lw  = 3'b010,
        load_f3_lbu = 3'b100,
        load_f3_lhu = 3'b101
    } load_f3_t;

    typedef enum logic [2:0] {
        store_f3_sb = 3'b000,
        store_f3_sh = 3'b001,
        store_f3_sw = 3'b010
    } store_f3_t;

    typedef enum logic [2:0] {
        branch_f3_beq  = 3'b000,
        branch_f3_bne  = 3'b001,
        branch_f3_blt  = 3'b100,
        branch_f3_bge  = 3'b101,
        branch_f3_bltu = 3'b110,
        branch_f3_bgeu = 3'b111
    } branch_f3_t;

    typedef enum logic [6:0] {
        base    = 7'b0000000,
        variant = 7'b0100000,
        muldiv  = 7'b0000001   // the M extension, sharing op_b_reg
    } funct7_t;

    // M extension. funct3[2] splits the two families: 0 is a multiply, whose
    // result is always available in one cycle, 1 is a divide, which is not.
    // Everything downstream keys off that bit rather than re-listing the ops.
    typedef enum logic [2:0] {
        md_f3_mul    = 3'b000,  // low 32 bits; signedness cannot change these
        md_f3_mulh   = 3'b001,  // high 32, signed   x signed
        md_f3_mulhsu = 3'b010,  // high 32, signed   x unsigned
        md_f3_mulhu  = 3'b011,  // high 32, unsigned x unsigned
        md_f3_div    = 3'b100,
        md_f3_divu   = 3'b101,
        md_f3_rem    = 3'b110,
        md_f3_remu   = 3'b111
    } md_f3_t;

    typedef enum logic [3:0] {
        alu_op_add  = 4'b0000,
        alu_op_sll  = 4'b0001,
        alu_op_sra  = 4'b0010,
        alu_op_sub  = 4'b0011,
        alu_op_xor  = 4'b0100,
        alu_op_srl  = 4'b0101,
        alu_op_or   = 4'b0110,
        alu_op_and  = 4'b0111,
        alu_op_slt  = 4'b1000,
        alu_op_sltu = 4'b1001
    } alu_ops;

    // Which immediate the instruction format calls for.
    typedef enum logic [2:0] {
        imm_i = 3'b000,
        imm_s = 3'b001,
        imm_b = 3'b010,
        imm_u = 3'b011,
        imm_j = 3'b100,
        imm_none = 3'b111
    } imm_sel_t;

    // Operand selects feeding the ALU.
    typedef enum logic {
        alu_a_rs1 = 1'b0,
        alu_a_pc  = 1'b1
    } alu_a_sel_t;

    typedef enum logic {
        alu_b_rs2 = 1'b0,
        alu_b_imm = 1'b1
    } alu_b_sel_t;

    // What gets written back to rd.
    typedef enum logic [1:0] {
        wb_alu   = 2'b00,
        wb_mem   = 2'b01,
        wb_pc4   = 2'b10,  // jal / jalr link value
        wb_imm   = 2'b11   // lui
    } wb_sel_t;

endpackage
