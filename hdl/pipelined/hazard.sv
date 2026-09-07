// Every hazard decision in the core lives here: what to forward, and when to
// stall. Nothing else in the pipeline decides either, so this file is the one
// place to read when results come out wrong.
//
// Combinational.

module hazard
import rv32i_types::*;
import pipelined_types::*;
(
    // From ID, for the load-use check.
    input  logic        id_valid,
    input  rv32i_opcode id_opcode,
    input  logic [4:0]  id_rs1_s,
    input  logic [4:0]  id_rs2_s,

    input  id_ex_t      id_ex,
    input  ex_mem_t     ex_mem,
    input  mem_wb_t     mem_wb,

    // From EX: an M instruction is executing, and whether its result exists
    // yet. A multiply always says yes; a divide says no for 33 cycles.
    input  logic        md_req,
    input  logic        md_ready,

    output fwd_sel_t    fwd_a,
    output fwd_sel_t    fwd_b,

    // Two stalls, and they are not the same shape. Getting them confused is the
    // easiest way to break this file, so the distinction is in the names:
    //
    //   stall_id  the instruction in ID cannot go yet. Freeze IF and IF/ID,
    //             put a BUBBLE into ID/EX. EX keeps running -- it is the load
    //             in EX that the stall is waiting on.
    //
    //   stall_ex  the instruction in EX is not finished. Freeze IF, IF/ID and
    //             ID/EX -- the instruction has to stay where it is -- and put
    //             a bubble into EX/MEM instead.
    //
    // They cannot overlap, and not by luck: stall_id needs a load in EX and
    // stall_ex needs an M instruction in EX, and both read the same id_ex. One
    // instruction is not both. cpu.sv relies on that when it orders the two.
    output logic        stall_id,
    output logic        stall_ex
);

    // Whether the instruction genuinely reads each source register. Without
    // this the load-use check would stall on lui, auipc and jal, whose rs1/rs2
    // fields are immediate bits rather than register numbers.
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

    // A load in MEM is excluded: its data has not returned, and ex_mem.alu_f
    // currently holds the address, so forwarding it would hand over an address
    // in place of a value.
    //
    // That exclusion is in fact unreachable, and deliberately kept anyway.
    // The load-use stall means a dependent consumer is still in ID while the
    // load is in MEM, and only reaches EX once the load is in WB -- so this
    // condition never actually selects. Mutation testing confirms it: deleting
    // the guard passes the whole suite. It stays because it makes the failure
    // mode on a broken stall "no forward" rather than "forward an address",
    // and because it states the invariant the stall is responsible for.
    logic mem_can_fwd, wb_can_fwd;

    assign mem_can_fwd = ex_mem.valid && ex_mem.regf_we && (ex_mem.rd_s != '0)
                         && (ex_mem.wb_sel != wb_mem);
    assign wb_can_fwd  = mem_wb.valid && mem_wb.regf_we && (mem_wb.rd_s != '0);

    // MEM wins over WB when both match: it is the more recent write.
    always_comb begin
        if (mem_can_fwd && (ex_mem.rd_s == id_ex.rs1_s)) begin
            fwd_a = fwd_mem;
        end else if (wb_can_fwd && (mem_wb.rd_s == id_ex.rs1_s)) begin
            fwd_a = fwd_wb;
        end else begin
            fwd_a = fwd_none;
        end

        if (mem_can_fwd && (ex_mem.rd_s == id_ex.rs2_s)) begin
            fwd_b = fwd_mem;
        end else if (wb_can_fwd && (mem_wb.rd_s == id_ex.rs2_s)) begin
            fwd_b = fwd_wb;
        end else begin
            fwd_b = fwd_none;
        end
    end

    // The one hazard forwarding cannot cover: a load in EX feeding the
    // instruction right behind it. Its data only returns at the end of MEM.
    // One stall pushes the consumer far enough that the WB path reaches it.
    logic load_use;

    assign load_use = id_ex.valid && id_ex.mem_read && (id_ex.rd_s != '0)
                      && ((reads_rs1(id_opcode) && (id_ex.rd_s == id_rs1_s))
                       || (reads_rs2(id_opcode) && (id_ex.rd_s == id_rs2_s)));

    assign stall_id = id_valid && load_use;

    // No id_valid term here. stall_id asks whether the ID stage holds
    // something real; stall_ex asks whether EX has finished, and md_req already
    // carries id_ex.valid, so ID has no bearing on the answer.
    //
    // Adding the term would not actually break anything, and that is worth
    // knowing rather than assuming: if_id.valid only falls on reset or a
    // redirect, a redirect can only come from a branch or jump in EX, and EX
    // holds a divide -- so ID is never empty while this signal matters.
    // Mutation testing agrees; gating it on id_valid passes every test except
    // the one below, which drives the combination directly.
    //
    // It is left out because the condition is not about ID, not because the
    // extra term would be observable.
    assign stall_ex = md_req && !md_ready;

endmodule
