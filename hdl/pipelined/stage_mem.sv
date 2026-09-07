// MEM: drives the data port and forwards the ALU result on to WB.
//
// Access convention, matching what the memory model asserts: dmem_addr is
// always word aligned and the byte lanes are picked by the masks, so a byte or
// halfword access presents the containing word's address with a narrow mask.
// A consequence worth knowing: under that convention an illegal mask IS a
// misaligned access.

module stage_mem
import rv32i_types::*;
import pipelined_types::*;
(
    input  ex_mem_t     ex_mem,

    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_rmask,
    output logic [3:0]  dmem_wmask,

    // The value this instruction will write back, for the forwarding network.
    // A load is excluded by hazard.sv, since its data has not returned yet and
    // alu_f currently holds the ADDRESS.
    output logic [31:0] fwd_value,

    output mem_wb_t     mem_wb
);

    logic [1:0] byte_off;
    logic [3:0] size_mask;

    assign byte_off  = ex_mem.alu_f[1:0];
    assign dmem_addr = {ex_mem.alu_f[31:2], 2'b00};

    // funct3[1:0] encodes the width identically for loads and stores: 00 byte,
    // 01 halfword, 10 word. 11 is not a legal width in RV32I.
    always_comb begin
        unique case (ex_mem.funct3[1:0])
            2'b00:   size_mask = 4'b0001;
            2'b01:   size_mask = 4'b0011;
            2'b10:   size_mask = 4'b1111;
            default: size_mask = 4'b0000;
        endcase
    end

    assign dmem_rmask = (ex_mem.valid && ex_mem.mem_read)
                        ? (size_mask << byte_off) : 4'b0000;
    assign dmem_wmask = (ex_mem.valid && ex_mem.mem_write)
                        ? (size_mask << byte_off) : 4'b0000;
    assign dmem_wdata = ex_mem.store_data << {byte_off, 3'b000};

    always_comb begin
        unique case (ex_mem.wb_sel)
            wb_alu: fwd_value = ex_mem.alu_f;
            wb_pc4: fwd_value = ex_mem.pc4;
            wb_imm: fwd_value = ex_mem.imm;
            wb_mem: fwd_value = '0;     // not available yet; hazard.sv blocks it
        endcase
    end

    always_comb begin
        mem_wb.valid    = ex_mem.valid;
        mem_wb.alu_f    = ex_mem.alu_f;
        mem_wb.pc4      = ex_mem.pc4;
        mem_wb.imm      = ex_mem.imm;
        mem_wb.byte_off = byte_off;
        mem_wb.rd_s     = ex_mem.rd_s;
        mem_wb.funct3   = ex_mem.funct3;
        mem_wb.wb_sel   = ex_mem.wb_sel;
        mem_wb.regf_we  = ex_mem.regf_we;
        mem_wb.mem_write   = ex_mem.mem_write;
        mem_wb.store_data  = ex_mem.store_data;
        mem_wb.is_halt  = ex_mem.is_halt;
    end

endmodule
