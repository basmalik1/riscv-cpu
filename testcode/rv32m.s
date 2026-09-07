# Per-instruction coverage for the RV32M multiply/divide extension, plus the
# pipeline interactions M introduces that the base ISA cannot reach.
#
# Same conventions as rv32i.s:
#   t0  breadcrumb -- the number of the check currently running.
#   t1  scratch for the expected value.
#   s0  count of checks passed, compared against the assembler's own tally.
# Tests may use a0-a7, t2-t6 and s1-s11. Not t0, t1 or s0.
#
# Two things here are worth more than the arithmetic. The first is the group of
# values the spec fixes by decree -- divide by zero, signed overflow, and which
# way truncation goes -- because those are the ones a plausible implementation
# gets plausibly wrong. The second is the last section: a divide holds EX for 34
# cycles, which is a stall of a shape the base ISA never produces, and every
# hazard that stall can compose with is worth reaching from a real program.

.set check_count, 0

.macro CHECK num, reg, expected
    li   t0, \num
    li   t1, \expected
    bne  \reg, t1, fail
    addi s0, s0, 1
    .set check_count, check_count + 1
.endm

.macro CHECK_REG num, reg, expected_reg
    li   t0, \num
    bne  \reg, \expected_reg, fail
    addi s0, s0, 1
    .set check_count, check_count + 1
.endm

.section ".init"
.globl _start
_start:
    li   s0, 0

    # ---------------------------------------------------------------- mul
    li   a0, 6
    li   a1, 7
    mul  a2, a0, a1
    CHECK 1, a2, 42

    li   a0, -6
    li   a1, 7
    mul  a2, a0, a1
    CHECK 2, a2, -42

    li   a0, -6
    li   a1, -7
    mul  a2, a0, a1
    CHECK 3, a2, 42

    li   a0, 0
    li   a1, 12345
    mul  a2, a0, a1
    CHECK 4, a2, 0

    # The low half is the same whichever way the operands are read, which is
    # why MUL has no signed and unsigned variants.
    li   a0, 0xffffffff
    li   a1, 0xffffffff
    mul  a2, a0, a1
    CHECK 5, a2, 1

    # ------------------------------------------------- mulh / mulhsu / mulhu
    # One operand pair, three instructions, three different answers. Nothing
    # else separates the three high multiplies as cleanly: a unit that treats
    # every one of them as signed passes two of these and fails the third.
    li     a0, 0xffffffff       # -1, or 2^32-1
    li     a1, 0xffffffff
    mulh   a2, a0, a1           # -1 * -1 = 1, high word 0
    CHECK 6, a2, 0
    mulhsu a2, a0, a1           # -1 * (2^32-1), high word all ones
    CHECK 7, a2, 0xffffffff
    mulhu  a2, a0, a1           # (2^32-1)^2 = 0xfffffffe00000001
    CHECK 8, a2, 0xfffffffe

    # The same three one step less extreme, where the sign of the answer
    # differs rather than its magnitude.
    li     a1, 2
    mulh   a2, a0, a1           # -1 * 2 = -2, high word all ones
    CHECK 9, a2, 0xffffffff
    mulhsu a2, a0, a1
    CHECK 10, a2, 0xffffffff
    mulhu  a2, a0, a1           # (2^32-1) * 2 = 0x1fffffffe
    CHECK 11, a2, 1

    # A product that genuinely needs the high word to be non-trivial.
    li     a0, 0x10000          # 2^16
    li     a1, 0x10000
    mul    a2, a0, a1           # 2^32, so the low word is zero
    CHECK 12, a2, 0
    mulhu  a2, a0, a1
    CHECK 13, a2, 1

    li     a0, 0x80000000       # -2^31
    li     a1, 0x80000000
    mulh   a2, a0, a1           # 2^62, high word 0x40000000
    CHECK 14, a2, 0x40000000
    mul    a2, a0, a1
    CHECK 15, a2, 0

    # ---------------------------------------------------- divu / remu
    li   a0, 42
    li   a1, 5
    divu a2, a0, a1
    CHECK 16, a2, 8
    remu a2, a0, a1
    CHECK 17, a2, 2

    li   a0, 100
    li   a1, 10
    divu a2, a0, a1
    CHECK 18, a2, 10
    remu a2, a0, a1
    CHECK 19, a2, 0

    # Divisor larger than the dividend: quotient zero, remainder untouched.
    li   a0, 3
    li   a1, 10
    divu a2, a0, a1
    CHECK 20, a2, 0
    remu a2, a0, a1
    CHECK 21, a2, 3

    li   a0, 0xdeadbeef
    li   a1, 1
    divu a2, a0, a1
    CHECK 22, a2, 0xdeadbeef

    # ------------------------------------------------------ div / rem
    li   a0, 42
    li   a1, 5
    div  a2, a0, a1
    CHECK 23, a2, 8
    rem  a2, a0, a1
    CHECK 24, a2, 2

    # RISC-V truncates toward zero, so -7/2 is -3 and not -4. The remainder
    # then takes the DIVIDEND's sign, which is what keeps the identity
    # a == (a/b)*b + a%b true.
    li   a0, -7
    li   a1, 2
    div  a2, a0, a1
    CHECK 25, a2, -3
    rem  a2, a0, a1
    CHECK 26, a2, -1

    li   a0, 7
    li   a1, -2
    div  a2, a0, a1
    CHECK 27, a2, -3
    rem  a2, a0, a1
    CHECK 28, a2, 1

    li   a0, -7
    li   a1, -2
    div  a2, a0, a1
    CHECK 29, a2, 3
    rem  a2, a0, a1
    CHECK 30, a2, -1

    # The same bits read two ways. As -1 the quotient is 0; as 2^32-1 it is
    # 0x7fffffff. This is the pair that catches a divider wired to the wrong
    # signedness, since every small positive case agrees.
    li   a0, 0xffffffff
    li   a1, 2
    div  a2, a0, a1
    CHECK 31, a2, 0
    divu a2, a0, a1
    CHECK 32, a2, 0x7fffffff
    rem  a2, a0, a1
    CHECK 33, a2, -1
    remu a2, a0, a1
    CHECK 34, a2, 1

    # ------------------------------------------- the two decreed cases
    # Divide by zero does not trap. RV32M has no way to signal one, so these
    # values are the specified behaviour rather than a fallback.
    li   a0, 42
    li   a1, 0
    div  a2, a0, a1
    CHECK 35, a2, -1
    divu a2, a0, a1
    CHECK 36, a2, 0xffffffff
    rem  a2, a0, a1
    CHECK 37, a2, 42
    remu a2, a0, a1
    CHECK 38, a2, 42

    li   a0, 0
    li   a1, 0
    div  a2, a0, a1
    CHECK 39, a2, -1
    rem  a2, a0, a1
    CHECK 40, a2, 0

    # -2^31 / -1 is not representable in 32 signed bits. The answer is the
    # dividend back, with a zero remainder, and again no trap.
    li   a0, 0x80000000
    li   a1, -1
    div  a2, a0, a1
    CHECK 41, a2, 0x80000000
    rem  a2, a0, a1
    CHECK 42, a2, 0

    # Read unsigned the same bits are 2^31 and 2^32-1, where nothing overflows
    # and the ordinary answer applies.
    divu a2, a0, a1
    CHECK 43, a2, 0
    remu a2, a0, a1
    CHECK 44, a2, 0x80000000

    # A divide targeting x0 still runs to completion; it just discards the
    # result. A core that skipped the work would fall out of step here only if
    # something downstream depended on the timing, so this mainly proves it
    # neither hangs nor writes x0.
    li   a0, 100
    li   a1, 7
    div  x0, a0, a1
    CHECK 45, x0, 0

    # ================================================================
    # pipeline interactions
    # ================================================================
    # A divide holds EX for 34 cycles. That is a stall of a shape the base ISA
    # never produces -- it freezes ID/EX and bubbles EX/MEM, where a load-use
    # stall does the opposite -- so everything it can compose with is worth
    # reaching from a real program rather than only from a unit test.

    # The result forwarded to the instruction immediately behind it. The
    # consumer enters EX on the cycle the divide leaves it, so this is the
    # MEM->EX path taken right as a long stall releases.
    li   a0, 100
    li   a1, 7
    div  a2, a0, a1             # 14
    addi a3, a2, 1
    CHECK 46, a3, 15

    # And at distance two, which is the WB->EX path.
    li   a0, 100
    li   a1, 7
    div  a2, a0, a1
    nop
    addi a3, a2, 1
    CHECK 47, a3, 15

    # Both operands of one instruction forwarded from two different divides.
    li   a0, 60
    li   a1, 4
    li   a4, 100
    li   a5, 5
    div  a2, a0, a1             # 15
    div  a3, a4, a5             # 20
    add  a6, a2, a3
    CHECK 48, a6, 35

    # Two divides back to back. The divider has to return to idle between
    # them; one that latched its done flag would hand the second the first
    # one's answer in a single cycle.
    li   a0, 100
    li   a1, 10
    li   a4, 81
    li   a5, 9
    div  a2, a0, a1             # 10
    div  a3, a4, a5             # 9
    CHECK 49, a2, 10
    CHECK 50, a3, 9

    # A load feeding a divide: a load-use stall and then a divide stall on
    # consecutive instructions, which is the only place the two shapes meet.
    la   a5, scratch
    li   a6, 84
    sw   a6, 0(a5)
    lw   a7, 0(a5)
    li   a1, 4
    div  a2, a7, a1             # 21
    CHECK 51, a2, 21

    # Same again with the load immediately before the divide, so the load-use
    # stall is genuinely in flight when the divide arrives.
    la   a5, scratch
    lw   a7, 0(a5)
    div  a2, a7, a1             # a1 still 4 -> 21
    CHECK 52, a2, 21

    # A divide feeding a taken branch. The comparison happens in EX on a value
    # produced by an instruction that just held EX for 34 cycles.
    li   a4, 5
    li   a0, 20
    li   a1, 4
    div  a2, a0, a1             # 5
    beq  a2, a4, m_br_taken
    j    fail
m_br_taken:
    li   t0, 53
    addi s0, s0, 1
    .set check_count, check_count + 1

    # And feeding a NOT-taken branch, so the fallthrough has to survive too.
    li   a0, 20
    li   a1, 4
    div  a2, a0, a1             # 5
    li   a4, 99
    beq  a2, a4, fail
    li   t0, 54
    addi s0, s0, 1
    .set check_count, check_count + 1

    # A divide immediately after a taken branch, so it starts with the front of
    # the pipeline still being refilled.
    li   a0, 144
    li   a1, 12
    beq  a0, a0, m_after_branch
    j    fail
m_after_branch:
    div  a2, a0, a1             # 12
    CHECK 55, a2, 12

    # A divide feeding a jalr target. The jump cannot resolve until the divide
    # has, which is a load-use-shaped dependency on a 34-cycle producer.
    la   a4, m_jalr_target
    li   a5, 1
    div  a6, a4, a5             # the target address, unchanged
    jalr ra, a6, 0
    j    fail
m_jalr_target:
    li   t0, 56
    addi s0, s0, 1
    .set check_count, check_count + 1

    # A divide result travelling out to memory and back, which takes it
    # through MEM and WB on the ordinary result path.
    li   a0, 144
    li   a1, 12
    div  a2, a0, a1             # 12
    la   a5, scratch
    sw   a2, 0(a5)
    lw   a6, 0(a5)
    CHECK 57, a6, 12

    # A multiply is combinational and must cost nothing, so it behaves exactly
    # like an ALU op under forwarding.
    li   a0, 6
    li   a1, 7
    mul  a2, a0, a1
    addi a3, a2, 1
    CHECK 58, a3, 43

    mul  a2, a0, a1
    mul  a3, a2, a0             # forwarded straight into another multiply
    CHECK 59, a3, 252

    # A multiply feeding a branch, forwarded at distance one.
    li   a4, 42
    mul  a2, a0, a1
    beq  a2, a4, m_mul_br
    j    fail
m_mul_br:
    li   t0, 60
    addi s0, s0, 1
    .set check_count, check_count + 1

    # -------------------------------------------------------- finished
    li   t0, 999
    li   t1, check_count
    bne  s0, t1, fail           # every check must have executed

pass:
    slti x0, x0, -256
    j    pass

fail:
    j    fail

.section ".data"
.align 2
scratch:
    .word 0
    .word 0
