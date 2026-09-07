// Multiply/divide unit: the whole of RV32M behind one interface.
//
// SEQUENTIAL picks the divider implementation and nothing else. The ISA
// semantics -- operand signedness, the sign fixup, and the two special cases
// the spec spells out -- are written once, outside the generate, so the two
// cores cannot drift apart on exactly the parts that are easy to get wrong.
// Same idea as regfile's WRITE_FIRST: one module, one behaviour, two costs.
//
// Why the split exists at all. Measured through synth/ against Nangate45, each
// unit registered on both sides so the number is a real FF-to-FF path:
//
//     a * b, combinational        6222 cells    2.923 ns
//     a / b, combinational        4604 cells   21.422 ns
//     restoring, 1 bit/cycle       534 cells    1.709 ns
//
// A combinational divide is five times the pipelined core's entire critical
// path, so the pipeline takes the iterative one and pays 33 cycles for it. The
// single-cycle core takes the combinational one deliberately: every
// instruction finishing in one cycle is the property that core exists to
// demonstrate, and the clock period it forces is the cost the comparison is
// meant to expose.
//
// Multiply stays combinational in both. At 2.923 ns it fits under the
// pipelined core's existing 4.140 ns path, so it buys area and no cycles.

module mdu
import rv32i_types::*;
#(
    parameter bit SEQUENTIAL = 1'b0
)(
    input  logic        clk,
    input  logic        rst,

    // Level, not a pulse: high for as long as an M instruction is the one in
    // execute. The sequential divider starts when it first sees this and
    // raises `ready` for the single cycle on which the instruction advances.
    input  logic        req,
    input  logic [2:0]  funct3,
    input  logic [31:0] a,
    input  logic [31:0] b,

    output logic [31:0] result,
    output logic        ready
);

    md_f3_t op;
    logic   is_div;

    assign op     = md_f3_t'(funct3);
    assign is_div = funct3[2];

    // ------------------------------------------------------------------
    // multiply
    // ------------------------------------------------------------------
    // One 33x33 signed multiply covers all four instructions: widening each
    // operand by a bit that is either its sign or a zero turns "signed" and
    // "unsigned" into a choice of operand rather than a choice of multiplier.
    logic a_signed, b_signed;

    always_comb begin
        unique case (op)
            md_f3_mulh:   {a_signed, b_signed} = 2'b11;
            md_f3_mulhsu: {a_signed, b_signed} = 2'b10;
            md_f3_mulhu:  {a_signed, b_signed} = 2'b00;
            // Includes md_f3_mul, whose low 32 bits are the same either way,
            // and the divides, which do not read these.
            default:      {a_signed, b_signed} = 2'b11;
        endcase
    end

    logic signed [32:0] mul_a, mul_b;
    // 64 bits, not the 66 the operand widths imply. Widening to 33 is only how
    // the signedness is expressed; the answer itself always fits in 64, the
    // widest case being unsigned x unsigned at 2^64 - 2^33 + 1. The two bits
    // above that are sign and overflow, and nothing reads them.
    logic signed [63:0] product;
    logic        [31:0] mul_result;

    assign mul_a   = signed'({a_signed & a[31], a});
    assign mul_b   = signed'({b_signed & b[31], b});
    assign product = mul_a * mul_b;

    assign mul_result = (op == md_f3_mul) ? product[31:0] : product[63:32];

    // ------------------------------------------------------------------
    // divide
    // ------------------------------------------------------------------
    // What the division result is computed from. The live inputs in the
    // combinational build; see the sequential branch for why they cannot be.
    logic [31:0] a_eff, b_eff;

    // Signed operands are divided by magnitude and the signs put back
    // afterwards, so a single unsigned engine serves all four instructions.
    logic div_signed, a_neg, b_neg;

    assign div_signed = (op == md_f3_div) || (op == md_f3_rem);
    assign a_neg      = div_signed && a_eff[31];
    assign b_neg      = div_signed && b_eff[31];

    logic [31:0] num_u, den_u;

    // Negating 32'h8000_0000 gives itself back, which read as unsigned is 2^31
    // -- the correct magnitude. The one case where that is not enough is the
    // signed overflow handled explicitly below.
    assign num_u = a_neg ? (~a_eff + 32'd1) : a_eff;
    assign den_u = b_neg ? (~b_eff + 32'd1) : b_eff;

    logic [31:0] quot_u, rem_u;
    logic        div_ready;

    generate
        if (SEQUENTIAL) begin : g_seq
            // Restoring division, one quotient bit per cycle. The dividend
            // shifts out of the top of `quo` into the remainder while the
            // quotient bit shifts into the bottom, so one register pair holds
            // both and the critical path is a single 33-bit subtract no matter
            // how many cycles have run.
            typedef enum logic [1:0] {
                s_idle = 2'b00,
                s_run  = 2'b01,
                s_done = 2'b10
            } div_state_t;

            div_state_t  state;
            logic [31:0] quo, rem, den, a_q, b_q;
            logic [5:0]  cnt;

            // rem < den holds at every step, so the shifted value needs 33 bits
            // while the result of the subtract still fits back into 32.
            logic [32:0] shifted, diff;
            logic        fits;

            assign shifted = {rem, quo[31]};
            assign diff    = shifted - {1'b0, den};
            assign fits    = ~diff[32];

            // The operands are captured on the starting cycle rather than read
            // live. While the divide holds EX, the pipeline registers behind it
            // fill with bubbles, so the forwarding selects feeding a and b move
            // underneath us -- the values are only trustworthy on the cycle the
            // instruction arrives. state == s_idle marks exactly that cycle.
            assign a_eff = (state == s_idle) ? a : a_q;
            assign b_eff = (state == s_idle) ? b : b_q;

            always_ff @(posedge clk) begin
                if (rst) begin
                    state <= s_idle;
                    quo   <= '0;
                    rem   <= '0;
                    den   <= '0;
                    cnt   <= '0;
                    a_q   <= '0;
                    b_q   <= '0;
                end else begin
                    unique case (state)
                        s_idle: begin
                            if (req && is_div) begin
                                a_q   <= a;
                                b_q   <= b;
                                quo   <= num_u;
                                rem   <= '0;
                                den   <= den_u;
                                cnt   <= 6'd32;
                                state <= s_run;
                            end
                        end

                        s_run: begin
                            rem <= fits ? diff[31:0] : shifted[31:0];
                            quo <= {quo[30:0], fits};
                            cnt <= cnt - 6'd1;
                            if (cnt == 6'd1) begin
                                state <= s_done;
                            end
                        end

                        // Exactly one cycle wide. The instruction advances on
                        // it, so by the next cycle EX holds something else and
                        // a back-to-back divide starts cleanly from s_idle.
                        s_done: state <= s_idle;

                        default: state <= s_idle;
                    endcase
                end
            end

            assign quot_u    = quo;
            assign rem_u     = rem;
            assign div_ready = (state == s_done);

        end else begin : g_comb
            // A divide by zero is x in simulation and meaningless in hardware,
            // so the divisor is forced to 1 and the answer discarded by the
            // special-case mux below.
            logic [31:0] safe_den;

            assign a_eff     = a;
            assign b_eff     = b;
            assign safe_den  = (den_u == '0) ? 32'd1 : den_u;
            assign quot_u    = num_u / safe_den;
            assign rem_u     = num_u % safe_den;
            assign div_ready = 1'b1;
        end
    endgenerate

    // The quotient takes the xor of the operand signs; the remainder takes the
    // dividend's, which is what makes REM truncate toward zero rather than
    // toward negative infinity.
    logic [31:0] quot_s, rem_s;

    assign quot_s = (a_neg ^ b_neg) ? (~quot_u + 32'd1) : quot_u;
    assign rem_s  = a_neg           ? (~rem_u  + 32'd1) : rem_u;

    // The two cases the ISA spells out, neither of which raises an exception --
    // RV32M has no architectural way to signal an error, so these values ARE
    // the specified behaviour rather than a fallback:
    //
    //   divide by zero    quotient all ones (-1 read as signed) and remainder
    //                     the dividend, for both signednesses
    //   signed overflow   -2^31 / -1 is not representable; DIV returns -2^31
    //                     and REM returns 0
    //
    // The overflow term is in fact redundant, and kept deliberately. Working
    // in magnitudes already produces the specified answer: |-2^31| is 2^31,
    // which an UNSIGNED 32-bit quotient holds exactly, and the sign fixup is a
    // no-op because negative divided by negative is positive -- so quot_s
    // lands on 0x8000_0000 by itself, and rem_u is 0 either way. Mutation
    // testing confirms it: forcing div_overflow low passes the entire suite.
    //
    // It stays because that argument depends on the intermediate being
    // unsigned and exactly 32 bits wide, which is a property of this
    // implementation rather than of the ISA. Anyone who narrows the divider or
    // moves it into the signed domain loses the coincidence silently; this
    // line states the requirement out loud.
    logic div_by_zero, div_overflow, want_quotient;

    assign div_by_zero   = (b_eff == '0);
    assign div_overflow  = div_signed && (a_eff == 32'h8000_0000)
                                      && (b_eff == 32'hffff_ffff);
    assign want_quotient = (op == md_f3_div) || (op == md_f3_divu);

    logic [31:0] div_result;

    always_comb begin
        if (div_by_zero) begin
            div_result = want_quotient ? 32'hffff_ffff : a_eff;
        end else if (div_overflow) begin
            div_result = want_quotient ? 32'h8000_0000 : 32'd0;
        end else begin
            div_result = want_quotient ? quot_s : rem_s;
        end
    end

    // ------------------------------------------------------------------
    assign result = is_div ? div_result : mul_result;
    assign ready  = is_div ? div_ready  : 1'b1;

endmodule
