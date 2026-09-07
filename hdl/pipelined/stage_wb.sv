// WB: extend the returned load data and choose what goes back to the register
// file. Also where retirement is reported, since this is the last stage an
// instruction can reach.

module stage_wb
import rv32i_types::*;
import pipelined_types::*;
(
    input  mem_wb_t     mem_wb,
    input  logic [31:0] dmem_rdata,

    output logic [31:0] wb_value,
    output logic [4:0]  rd_s,
    output logic        regf_we,

    // Reported from here rather than from the fetch bus. An instruction two
    // past a taken branch is fetched speculatively and squashed, so decoding
    // halt at fetch would report a halt the program never executed.
    output logic        halt,
    output logic        commit,

    // Commit trace. Same reasoning as halt: only an instruction that reaches
    // WB actually happened, so this is the only stage that can report it.
    output logic [31:0] commit_pc,
    output logic        commit_regf_we,
    output logic [4:0]  commit_rd_s,
    output logic [31:0] commit_rd_v
);

    logic [31:0] load_word, load_data;

    assign load_word = dmem_rdata >> {mem_wb.byte_off, 3'b000};

    always_comb begin
        unique case (load_f3_t'(mem_wb.funct3))
            load_f3_lb:  load_data = {{24{load_word[7]}},  load_word[7:0]};
            load_f3_lh:  load_data = {{16{load_word[15]}}, load_word[15:0]};
            load_f3_lw:  load_data = load_word;
            load_f3_lbu: load_data = {24'b0, load_word[7:0]};
            load_f3_lhu: load_data = {16'b0, load_word[15:0]};
            default:     load_data = load_word;
        endcase
    end

    always_comb begin
        unique case (mem_wb.wb_sel)
            wb_alu: wb_value = mem_wb.alu_f;
            wb_mem: wb_value = load_data;
            wb_pc4: wb_value = mem_wb.pc4;
            wb_imm: wb_value = mem_wb.imm;
        endcase
    end

    assign rd_s    = mem_wb.rd_s;
    assign regf_we = mem_wb.valid && mem_wb.regf_we;
    assign halt    = mem_wb.valid && mem_wb.is_halt;
    assign commit  = mem_wb.valid;

    // pc4 is carried for the jal/jalr link value; the instruction's own PC is
    // four below it. Derived rather than carried because adding a pc field to
    // ex_mem_t and mem_wb_t would be 64 flip-flops of verification-only state,
    // and this subtract feeds nothing but an output port.
    assign commit_pc      = mem_wb.pc4 - 32'd4;
    assign commit_regf_we = regf_we;
    assign commit_rd_s    = mem_wb.rd_s;
    assign commit_rd_v    = wb_value;

endmodule
