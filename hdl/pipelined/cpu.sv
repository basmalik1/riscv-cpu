// Five-stage pipelined RV32I core: IF, ID, EX, MEM, WB.
//
// Assumes a SYNCHRONOUS-READ memory -- data arrives one cycle after the
// address. That is not a compromise here, it is the point: the fetch issued in
// IF lands at the start of ID, and the load issued in MEM lands at the start of
// WB, so the pipeline registers absorb exactly the latency that forced the
// single-cycle core into a combinational read. Signals are named for the stage
// they FEED, so id_* is the IF/ID output and so on.
//
// Hazards handled here:
//
//   * RAW, through forwarding from MEM and WB back into EX. The MEM-stage
//     value wins when both match, being the more recent.
//   * Load-use, which forwarding cannot fix, by stalling one cycle. After the
//     stall the load is in WB and its data is available to forward.
//   * Control, by resolving branches and jumps in EX and squashing the two
//     instructions already in flight behind them.
//
// Not handled, because RV32I without CSRs does not raise them: exceptions,
// interrupts, and memory ordering.

module cpu
import rv32i_types::*;
#(
    parameter bit [31:0] RESET_PC = 32'h8000_0000
)(
    input  logic        clk,
    input  logic        rst,

    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_rmask,
    output logic [3:0]  dmem_wmask,
    input  logic [31:0] dmem_rdata,

    // Asserted when the halt instruction reaches WB. Deliberately not decoded
    // from the fetch bus: a halt sitting just past a taken branch gets fetched
    // speculatively, and reporting that as a halt would turn a failing test
    // into a passing one.
    output logic        halt,

    // Asserted when an instruction retires, so the testbench can measure
    // IPC. Bubbles from stalls and squashes do not count.
    output logic        commit
);

    logic        stall;
    logic        redirect;
    logic [31:0] redirect_pc;

    // ==================================================================
    // IF
    // ==================================================================
    logic [31:0] pc;

    assign imem_addr = pc;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= RESET_PC;
        end else if (redirect) begin
            pc <= redirect_pc;
        end else if (!stall) begin
            pc <= pc + 32'd4;
        end
    end

    // ------------------------------ IF/ID -----------------------------
    // There is no instruction register here: the memory's own output register
    // is it. This stage only has to remember which PC the in-flight fetch
    // belongs to.
    logic [31:0] id_pc;
    logic        id_valid;

    always_ff @(posedge clk) begin
        if (rst || redirect) begin
            id_valid <= 1'b0;
            id_pc    <= '0;
        end else if (!stall) begin
            id_valid <= 1'b1;
            id_pc    <= pc;
        end
    end

    // ==================================================================
    // ID
    // ==================================================================
    logic [31:0] id_inst;
    logic [4:0]  id_rs1_s, id_rs2_s, id_rd_s;

    // A stall cannot be served by holding the PC. The memory read is
    // registered, and by the time ID knows it must stall the PC has already
    // advanced, so the next fetch returns the FOLLOWING instruction while ID
    // still needs the current one -- which issues the stalled instruction
    // twice. So capture it on the first stalled cycle and replay from here.
    logic [31:0] held_inst;
    logic        held_valid;

    always_ff @(posedge clk) begin
        if (rst || redirect) begin
            held_valid <= 1'b0;
        end else if (stall && !held_valid) begin
            held_inst  <= imem_rdata;
            held_valid <= 1'b1;
        end else if (!stall) begin
            held_valid <= 1'b0;
        end
    end

    assign id_inst  = held_valid ? held_inst : imem_rdata;
    assign id_rs1_s = id_inst[19:15];
    assign id_rs2_s = id_inst[24:20];
    assign id_rd_s  = id_inst[11:7];

    alu_ops     id_aluop;
    alu_a_sel_t id_alu_a_sel;
    alu_b_sel_t id_alu_b_sel;
    imm_sel_t   id_imm_sel;
    wb_sel_t    id_wb_sel;
    logic       id_regf_we, id_mem_read, id_mem_write;
    logic       id_is_branch, id_is_jal, id_is_jalr;

    control control_unit (
        .inst      (id_inst),
        .aluop     (id_aluop),
        .alu_a_sel (id_alu_a_sel),
        .alu_b_sel (id_alu_b_sel),
        .imm_sel   (id_imm_sel),
        .wb_sel    (id_wb_sel),
        .regf_we   (id_regf_we),
        .mem_read  (id_mem_read),
        .mem_write (id_mem_write),
        .is_branch (id_is_branch),
        .is_jal    (id_is_jal),
        .is_jalr   (id_is_jalr)
    );

    logic [31:0] id_imm;

    always_comb begin
        unique case (id_imm_sel)
            imm_i:   id_imm = {{20{id_inst[31]}}, id_inst[31:20]};
            imm_s:   id_imm = {{20{id_inst[31]}}, id_inst[31:25], id_inst[11:7]};
            imm_b:   id_imm = {{20{id_inst[31]}}, id_inst[7], id_inst[30:25],
                               id_inst[11:8], 1'b0};
            imm_u:   id_imm = {id_inst[31:12], 12'b0};
            imm_j:   id_imm = {{12{id_inst[31]}}, id_inst[19:12], id_inst[20],
                               id_inst[30:21], 1'b0};
            default: id_imm = '0;
        endcase
    end

    // Whether the instruction genuinely reads each source register. Used only
    // by the load-use check: treating every instruction as a reader would stall
    // on lui, auipc and jal, whose rs1/rs2 fields are immediate bits.
    function automatic bit reads_rs1(rv32i_opcode op);
        case (op)
            op_b_lui, op_b_auipc, op_b_jal: reads_rs1 = 1'b0;
            default:                        reads_rs1 = 1'b1;
        endcase
    endfunction

    function automatic bit reads_rs2(rv32i_opcode op);
        case (op)
            op_b_br, op_b_store, op_b_reg: reads_rs2 = 1'b1;
            default:                       reads_rs2 = 1'b0;
        endcase
    endfunction

    rv32i_opcode id_opcode;
    assign id_opcode = rv32i_opcode'(id_inst[6:0]);

    logic [31:0] id_rs1_v, id_rs2_v;

    // Declared early because ID reads them back through the write-first
    // register file and the forwarding network reads them in EX.
    logic [31:0] wb_value;
    logic [4:0]  wb_rd_s;
    logic        wb_regf_we, wb_valid;

    regfile #(
        .WRITE_FIRST (1'b1)
    ) regfile_inst (
        .clk    (clk),
        .rst    (rst),
        .regf_we(wb_valid && wb_regf_we),
        .rd_v   (wb_value),
        .rs1_s  (id_rs1_s),
        .rs2_s  (id_rs2_s),
        .rd_s   (wb_rd_s),
        .rs1_v  (id_rs1_v),
        .rs2_v  (id_rs2_v)
    );

    // ------------------------------ ID/EX -----------------------------
    logic [31:0] ex_pc, ex_imm, ex_rs1_v, ex_rs2_v;
    logic [4:0]  ex_rs1_s, ex_rs2_s, ex_rd_s;
    logic [2:0]  ex_funct3;
    alu_ops      ex_aluop;
    alu_a_sel_t  ex_alu_a_sel;
    alu_b_sel_t  ex_alu_b_sel;
    wb_sel_t     ex_wb_sel;
    logic        ex_regf_we, ex_mem_read, ex_mem_write;
    logic        ex_is_branch, ex_is_jal, ex_is_jalr, ex_is_halt, ex_valid;

    always_ff @(posedge clk) begin
        if (rst || redirect || stall) begin
            // A stall inserts a bubble here rather than holding, so the
            // instruction stuck in ID is simply re-decoded next cycle.
            ex_valid     <= 1'b0;
            ex_regf_we   <= 1'b0;
            ex_mem_read  <= 1'b0;
            ex_mem_write <= 1'b0;
            ex_is_branch <= 1'b0;
            ex_is_jal    <= 1'b0;
            ex_is_jalr   <= 1'b0;
            ex_is_halt   <= 1'b0;
        end else begin
            ex_valid     <= id_valid;
            ex_regf_we   <= id_regf_we;
            ex_mem_read  <= id_mem_read;
            ex_mem_write <= id_mem_write;
            ex_is_branch <= id_is_branch;
            ex_is_jal    <= id_is_jal;
            ex_is_jalr   <= id_is_jalr;
            ex_is_halt   <= (id_inst == HALT_INST);
        end
    end

    always_ff @(posedge clk) begin
        ex_pc        <= id_pc;
        ex_imm       <= id_imm;
        ex_rs1_v     <= id_rs1_v;
        ex_rs2_v     <= id_rs2_v;
        ex_rs1_s     <= id_rs1_s;
        ex_rs2_s     <= id_rs2_s;
        ex_rd_s      <= id_rd_s;
        ex_funct3    <= id_inst[14:12];
        ex_aluop     <= id_aluop;
        ex_alu_a_sel <= id_alu_a_sel;
        ex_alu_b_sel <= id_alu_b_sel;
        ex_wb_sel    <= id_wb_sel;
    end

    // ==================================================================
    // EX
    // ==================================================================
    logic [31:0] mem_alu_f, mem_pc4, mem_imm, mem_store_data;
    logic [4:0]  mem_rd_s;
    logic [2:0]  mem_funct3;
    wb_sel_t     mem_wb_sel;
    logic        mem_regf_we, mem_mem_read, mem_mem_write, mem_is_halt, mem_valid;

    // What the MEM-stage instruction will eventually write. Known for
    // everything except a load, whose data has not come back yet -- which is
    // exactly the case the load-use stall exists to keep from mattering.
    // Forwarding mem_alu_f for a load would hand over the ADDRESS.
    logic [31:0] mem_fwd_value;
    logic        mem_fwd_ok;

    always_comb begin
        unique case (mem_wb_sel)
            wb_alu: mem_fwd_value = mem_alu_f;
            wb_pc4: mem_fwd_value = mem_pc4;
            wb_imm: mem_fwd_value = mem_imm;
            wb_mem: mem_fwd_value = '0;
        endcase
    end

    assign mem_fwd_ok = mem_valid && mem_regf_we && (mem_rd_s != '0)
                        && (mem_wb_sel != wb_mem);

    logic wb_fwd_ok;
    assign wb_fwd_ok = wb_valid && wb_regf_we && (wb_rd_s != '0);

    logic [31:0] fwd_rs1, fwd_rs2;

    always_comb begin
        if (mem_fwd_ok && (mem_rd_s == ex_rs1_s)) begin
            fwd_rs1 = mem_fwd_value;
        end else if (wb_fwd_ok && (wb_rd_s == ex_rs1_s)) begin
            fwd_rs1 = wb_value;
        end else begin
            fwd_rs1 = ex_rs1_v;
        end

        if (mem_fwd_ok && (mem_rd_s == ex_rs2_s)) begin
            fwd_rs2 = mem_fwd_value;
        end else if (wb_fwd_ok && (wb_rd_s == ex_rs2_s)) begin
            fwd_rs2 = wb_value;
        end else begin
            fwd_rs2 = ex_rs2_v;
        end
    end

    logic [31:0] alu_a, alu_b, alu_f;

    always_comb begin
        unique case (ex_alu_a_sel)
            alu_a_rs1: alu_a = fwd_rs1;
            alu_a_pc:  alu_a = ex_pc;
        endcase
        unique case (ex_alu_b_sel)
            alu_b_rs2: alu_b = fwd_rs2;
            alu_b_imm: alu_b = ex_imm;
        endcase
    end

    alu alu_inst (
        .aluop(ex_aluop),
        .a    (alu_a),
        .b    (alu_b),
        .f    (alu_f)
    );

    logic branch_taken;

    always_comb begin
        unique case (branch_f3_t'(ex_funct3))
            branch_f3_beq:  branch_taken = (fwd_rs1 == fwd_rs2);
            branch_f3_bne:  branch_taken = (fwd_rs1 != fwd_rs2);
            branch_f3_blt:  branch_taken = (signed'(fwd_rs1) <  signed'(fwd_rs2));
            branch_f3_bge:  branch_taken = (signed'(fwd_rs1) >= signed'(fwd_rs2));
            branch_f3_bltu: branch_taken = (fwd_rs1 <  fwd_rs2);
            branch_f3_bgeu: branch_taken = (fwd_rs1 >= fwd_rs2);
            default:        branch_taken = 1'b0;
        endcase
    end

    // Fetch runs straight ahead, so a taken branch or any jump costs the two
    // instructions already behind it. Both are squashed by this redirect.
    assign redirect    = ex_valid && (ex_is_jal || ex_is_jalr
                                      || (ex_is_branch && branch_taken));
    assign redirect_pc = ex_is_jalr ? {alu_f[31:1], 1'b0} : alu_f;

    // ----------------------------- EX/MEM -----------------------------
    // Nothing past EX ever stalls; bubbles simply flow through.
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_valid     <= 1'b0;
            mem_regf_we   <= 1'b0;
            mem_mem_read  <= 1'b0;
            mem_mem_write <= 1'b0;
            mem_is_halt   <= 1'b0;
        end else begin
            mem_valid     <= ex_valid;
            mem_regf_we   <= ex_regf_we;
            mem_mem_read  <= ex_mem_read;
            mem_mem_write <= ex_mem_write;
            mem_is_halt   <= ex_is_halt;
        end
    end

    always_ff @(posedge clk) begin
        mem_alu_f      <= alu_f;
        mem_pc4        <= ex_pc + 32'd4;
        mem_imm        <= ex_imm;
        mem_store_data <= fwd_rs2;
        mem_rd_s       <= ex_rd_s;
        mem_funct3     <= ex_funct3;
        mem_wb_sel     <= ex_wb_sel;
    end

    // ==================================================================
    // MEM
    // ==================================================================
    logic [1:0] mem_byte_off;
    logic [3:0] size_mask;

    assign mem_byte_off = mem_alu_f[1:0];
    assign dmem_addr    = {mem_alu_f[31:2], 2'b00};

    always_comb begin
        unique case (mem_funct3[1:0])
            2'b00:   size_mask = 4'b0001;
            2'b01:   size_mask = 4'b0011;
            2'b10:   size_mask = 4'b1111;
            default: size_mask = 4'b0000;
        endcase
    end

    assign dmem_rmask = (mem_valid && mem_mem_read)
                        ? (size_mask << mem_byte_off) : 4'b0000;
    assign dmem_wmask = (mem_valid && mem_mem_write)
                        ? (size_mask << mem_byte_off) : 4'b0000;
    assign dmem_wdata = mem_store_data << {mem_byte_off, 3'b000};

    // ----------------------------- MEM/WB -----------------------------
    // Named wb_link / wb_immval rather than wb_pc4 / wb_imm: those are
    // wb_sel_t enum items, and shadowing them is illegal here.
    logic [31:0] wb_alu_f, wb_link, wb_immval;
    logic [1:0]  wb_byte_off;
    logic [2:0]  wb_funct3;
    wb_sel_t     wb_wb_sel;
    logic        wb_is_halt;

    always_ff @(posedge clk) begin
        if (rst) begin
            wb_valid   <= 1'b0;
            wb_regf_we <= 1'b0;
            wb_is_halt <= 1'b0;
        end else begin
            wb_valid   <= mem_valid;
            wb_regf_we <= mem_regf_we;
            wb_is_halt <= mem_is_halt;
        end
    end

    always_ff @(posedge clk) begin
        wb_alu_f    <= mem_alu_f;
        wb_link     <= mem_pc4;
        wb_immval   <= mem_imm;
        wb_rd_s     <= mem_rd_s;
        wb_funct3   <= mem_funct3;
        wb_wb_sel   <= mem_wb_sel;
        wb_byte_off <= mem_byte_off;
    end

    // ==================================================================
    // WB
    // ==================================================================
    logic [31:0] load_word, load_data;

    assign load_word = dmem_rdata >> {wb_byte_off, 3'b000};

    always_comb begin
        unique case (load_f3_t'(wb_funct3))
            load_f3_lb:  load_data = {{24{load_word[7]}},  load_word[7:0]};
            load_f3_lh:  load_data = {{16{load_word[15]}}, load_word[15:0]};
            load_f3_lw:  load_data = load_word;
            load_f3_lbu: load_data = {24'b0, load_word[7:0]};
            load_f3_lhu: load_data = {16'b0, load_word[15:0]};
            default:     load_data = load_word;
        endcase
    end

    always_comb begin
        unique case (wb_wb_sel)
            wb_alu: wb_value = wb_alu_f;
            wb_mem: wb_value = load_data;
            wb_pc4: wb_value = wb_link;
            wb_imm: wb_value = wb_immval;
        endcase
    end

    assign halt   = wb_valid && wb_is_halt;
    assign commit = wb_valid;

    // ==================================================================
    // hazard: load-use
    // ==================================================================
    // Forwarding cannot cover a load feeding the very next instruction, since
    // the data only comes back at the end of MEM. One stall pushes the consumer
    // far enough that the WB forwarding path covers it.
    logic load_use;

    assign load_use = ex_valid && ex_mem_read && (ex_rd_s != '0)
                      && ((reads_rs1(id_opcode) && (ex_rd_s == id_rs1_s))
                       || (reads_rs2(id_opcode) && (ex_rd_s == id_rs2_s)));

    assign stall = id_valid && load_use;

endmodule
