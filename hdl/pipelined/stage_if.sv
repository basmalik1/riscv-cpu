// IF: owns the program counter and delivers a stable instruction to ID.
//
// The only stage with state of its own. The PC is not a pipeline register --
// it is IF's own, which is why it lives here while the four pipeline registers
// stay in cpu.sv with the rest of the sequencing.
//
// Two things make this more than "pc plus four":
//
//   * Redirect. A taken branch or a jump resolves in EX, by which point two
//     instructions behind it have already been fetched. cpu.sv squashes those;
//     this stage just takes the new PC.
//
//   * Stall. Holding the PC does NOT hold the instruction when the memory read
//     is registered: by the time ID knows it must stall, the PC has already
//     advanced, so the next fetch returns the FOLLOWING instruction while ID
//     still needs the current one. Left alone that issues the stalled
//     instruction twice. So the instruction is captured on the first stalled
//     cycle and replayed from here.

module stage_if
import rv32i_types::*;
import pipelined_types::*;
#(
    parameter bit [31:0] RESET_PC = 32'h8000_0000
)(
    input  logic        clk,
    input  logic        rst,

    input  logic        stall,
    input  logic        redirect,
    input  logic [31:0] redirect_pc,

    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    // What ID should decode this cycle. Note this does not pass through the
    // IF/ID register: the memory's own output register is that register, which
    // is the whole reason a synchronous-read memory suits a pipeline. Only the
    // PC needs carrying alongside it.
    output logic [31:0] inst,

    // Payload for the IF/ID register, which cpu.sv clocks and squashes.
    output if_id_t      if_id_n
);

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

    assign inst = held_valid ? held_inst : imem_rdata;

    always_comb begin
        if_id_n.valid = 1'b1;
        if_id_n.pc    = pc;
    end

endmodule
