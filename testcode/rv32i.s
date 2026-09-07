# Per-instruction coverage for the RV32I base set.
#
# Register convention inside this file:
#   t0  breadcrumb -- the number of the check currently running. On a failure
#       the core spins with this still set, so the failing check is readable
#       from the waveform without bisecting the program.
#   t1  scratch for the expected value.
#   s0  count of checks passed, compared against the assembler's own tally at
#       the end so a skipped check is caught even if every executed check
#       agreed.
# Tests may use a0-a7, t2-t6 and s1-s11. Not t0, t1 or s0.

.set check_count, 0

.macro CHECK num, reg, expected
    li   t0, \num
    li   t1, \expected
    bne  \reg, t1, fail
    addi s0, s0, 1
    .set check_count, check_count + 1
.endm

# Same, but compares against another register -- for values like a return
# address that have no assemble-time constant.
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

    # ---------------------------------------------------------------- lui
    lui  a0, 0x12345
    CHECK 1, a0, 0x12345000

    lui  a0, 0xfffff
    CHECK 2, a0, 0xfffff000

    # -------------------------------------------------------------- auipc
    # auipc has no constant answer, so cross-check it against `la`, which the
    # assembler expands to its own auipc/addi pair targeting the same label.
auipc_here:
    auipc a0, 0
    la    a1, auipc_here
    li    t0, 3
    bne   a0, a1, fail
    addi  s0, s0, 1
    .set check_count, check_count + 1

    # ------------------------------------------------------- addi / slti
    li   a0, 10
    addi a1, a0, 5
    CHECK 10, a1, 15

    addi a1, a0, -3
    CHECK 11, a1, 7

    li   a0, -5
    slti a1, a0, 0
    CHECK 12, a1, 1

    slti a1, a0, -10
    CHECK 13, a1, 0

    li    a0, -1
    sltiu a1, a0, 1             # 0xffffffff < 1 unsigned is false
    CHECK 14, a1, 0

    li    a0, 0
    sltiu a1, a0, 1
    CHECK 15, a1, 1

    # ------------------------------------------------ xori / ori / andi
    li   a0, 0xff
    xori a1, a0, 0x0f
    CHECK 16, a1, 0xf0

    li   a0, 0xf0
    ori  a1, a0, 0x0f
    CHECK 17, a1, 0xff

    li   a0, 0xff
    andi a1, a0, 0x0f
    CHECK 18, a1, 0x0f

    # ------------------------------------------ slli / srli / srai (imm)
    li   a0, 1
    slli a1, a0, 31
    CHECK 19, a1, 0x80000000

    li   a0, 0x80000000
    srli a1, a0, 31
    CHECK 20, a1, 1

    srai a1, a0, 31             # arithmetic: sign floods
    CHECK 21, a1, -1

    srai a1, a0, 4
    CHECK 22, a1, 0xf8000000

    # ------------------------------------------------------- add / sub
    li   a0, 100
    li   a1, 42
    add  a2, a0, a1
    CHECK 30, a2, 142

    sub  a2, a0, a1
    CHECK 31, a2, 58

    sub  a2, a1, a0             # negative result
    CHECK 32, a2, -58

    # ------------------------------------------------------ slt / sltu
    li   a0, -1
    li   a1, 1
    slt  a2, a0, a1             # signed: -1 < 1
    CHECK 33, a2, 1

    sltu a2, a0, a1             # unsigned: 0xffffffff < 1 is false
    CHECK 34, a2, 0

    # ------------------------------------------------ xor / or / and
    li   a0, 0xff00
    li   a1, 0x0ff0
    xor  a2, a0, a1
    CHECK 35, a2, 0xf0f0

    or   a2, a0, a1
    CHECK 36, a2, 0xfff0

    and  a2, a0, a1
    CHECK 37, a2, 0x0f00

    # ----------------------------------------------- sll / srl / sra
    li   a0, 1
    li   a1, 4
    sll  a2, a0, a1
    CHECK 38, a2, 16

    li   a0, 0x80000000
    srl  a2, a0, a1
    CHECK 39, a2, 0x08000000

    sra  a2, a0, a1
    CHECK 40, a2, 0xf8000000

    # Shift amount is rs2[4:0] only: 33 must shift by 1, not 33.
    li   a0, 1
    li   a1, 33
    sll  a2, a0, a1
    CHECK 41, a2, 2

    # -------------------------------------------------------- lw / sw
    la   a3, scratch
    li   a0, 0x89abcdef
    sw   a0, 0(a3)
    lw   a1, 0(a3)
    CHECK 50, a1, 0x89abcdef

    # ------------------------------------------- lb at every byte offset
    lb   a1, 0(a3)              # 0xef -> sign extended
    CHECK 51, a1, 0xffffffef

    lb   a1, 1(a3)              # 0xcd
    CHECK 52, a1, 0xffffffcd

    lb   a1, 2(a3)              # 0xab
    CHECK 53, a1, 0xffffffab

    lb   a1, 3(a3)              # 0x89
    CHECK 54, a1, 0xffffff89

    # ---------------------------------------------------------- lbu
    lbu  a1, 0(a3)
    CHECK 55, a1, 0x000000ef

    lbu  a1, 3(a3)
    CHECK 56, a1, 0x00000089

    # ----------------------------------------------------- lh / lhu
    lh   a1, 0(a3)              # 0xcdef -> sign extended
    CHECK 57, a1, 0xffffcdef

    lh   a1, 2(a3)              # 0x89ab
    CHECK 58, a1, 0xffff89ab

    lhu  a1, 0(a3)
    CHECK 59, a1, 0x0000cdef

    lhu  a1, 2(a3)
    CHECK 60, a1, 0x000089ab

    # ------------------------------------------ sb at every byte offset
    sw   zero, 0(a3)
    li   a0, 0xaa
    sb   a0, 0(a3)
    lw   a1, 0(a3)
    CHECK 61, a1, 0x000000aa

    sw   zero, 0(a3)
    sb   a0, 1(a3)
    lw   a1, 0(a3)
    CHECK 62, a1, 0x0000aa00

    sw   zero, 0(a3)
    sb   a0, 2(a3)
    lw   a1, 0(a3)
    CHECK 63, a1, 0x00aa0000

    sw   zero, 0(a3)
    sb   a0, 3(a3)
    lw   a1, 0(a3)
    CHECK 64, a1, 0xaa000000

    # sb must leave the other three lanes alone.
    li   a0, -1
    sw   a0, 0(a3)
    li   a0, 0x00
    sb   a0, 1(a3)
    lw   a1, 0(a3)
    CHECK 65, a1, 0xffff00ff

    # ---------------------------------------------------------- sh
    sw   zero, 0(a3)
    li   a0, 0xbeef
    sh   a0, 0(a3)
    lw   a1, 0(a3)
    CHECK 66, a1, 0x0000beef

    sw   zero, 0(a3)
    sh   a0, 2(a3)
    lw   a1, 0(a3)
    CHECK 67, a1, 0xbeef0000

    # sh must leave the other halfword alone.
    li   a0, -1
    sw   a0, 0(a3)
    li   a0, 0
    sh   a0, 2(a3)
    lw   a1, 0(a3)
    CHECK 68, a1, 0x0000ffff

    # --------------------------------------------------- branches taken
    li   a0, 5
    li   a1, 5
    li   a2, 0
    beq  a0, a1, 1f
    j    fail
1:  addi a2, a2, 1
    CHECK 70, a2, 1

    li   a1, 6
    bne  a0, a1, 1f
    j    fail
1:  addi a2, a2, 1
    CHECK 71, a2, 2

    li   a0, -1
    li   a1, 1
    blt  a0, a1, 1f             # signed
    j    fail
1:  addi a2, a2, 1
    CHECK 72, a2, 3

    bge  a1, a0, 1f             # signed
    j    fail
1:  addi a2, a2, 1
    CHECK 73, a2, 4

    bltu a1, a0, 1f             # unsigned: 1 < 0xffffffff
    j    fail
1:  addi a2, a2, 1
    CHECK 74, a2, 5

    bgeu a0, a1, 1f             # unsigned: 0xffffffff >= 1
    j    fail
1:  addi a2, a2, 1
    CHECK 75, a2, 6

    # ----------------------------------------------- branches not taken
    li   a0, 5
    li   a1, 6
    li   a2, 0
    beq  a0, a1, fail
    addi a2, a2, 1
    bne  a0, a0, fail
    addi a2, a2, 1
    blt  a1, a0, fail
    addi a2, a2, 1
    bge  a0, a1, fail
    addi a2, a2, 1
    bltu a1, a0, fail
    addi a2, a2, 1
    bgeu a0, a1, fail
    addi a2, a2, 1
    CHECK 76, a2, 6

    # ------------------------------------------- pipeline hazards
    # Correct on any core, but only interesting on a pipelined one. A load
    # feeding the very next instruction is the single case forwarding cannot
    # cover, so it needs a stall; the rest exercise the forwarding paths at
    # distance one and two.
    la   a3, scratch
    li   a0, 0x11223344
    sw   a0, 0(a3)

    lw   a4, 0(a3)
    addi a5, a4, 1              # load-use, distance 1
    CHECK 90, a5, 0x11223345

    li   a6, 0x11223344
    lw   a4, 0(a3)
    beq  a4, a6, 1f             # load feeding a branch, distance 1
    j    fail
1:  CHECK 91, a4, 0x11223344

    lw   a4, 0(a3)
    sw   a4, 4(a3)              # load feeding store data, distance 1
    lw   a7, 4(a3)
    CHECK 92, a7, 0x11223344

    # Back-to-back ALU dependencies: forwarding from MEM and from WB.
    li   a0, 1
    addi a0, a0, 1              # distance 1
    addi a0, a0, 1              # distance 1 again
    CHECK 93, a0, 3

    li   a0, 10
    addi a1, a0, 1              # 11
    addi a2, a0, 2              # 12, distance 2 from the li
    add  a0, a1, a2             # both operands forwarded
    CHECK 94, a0, 23

    # --------------------------------------- hazard interactions
    # A load feeding a jump's base register. jalr reads rs1, so this has to
    # stall exactly like any other load-use -- and getting it wrong jumps to
    # a stale address rather than producing a wrong number, so it fails as a
    # runaway rather than a mismatch.
    la   a0, scratch
    la   a1, hz_target
    sw   a1, 0(a0)
    li   a2, 0
    lw   a3, 0(a0)
    jalr ra, a3, 0              # load-use on a jump target
hz_back:
    CHECK 95, a2, 1

    # Two taken branches back to back. The second is the first instruction
    # fetched after a redirect, so this lands a redirect directly on another.
    li   a4, 0
    beq  x0, x0, 1f
    j    fail
1:  beq  x0, x0, 2f
    j    fail
2:  addi a4, a4, 1
    CHECK 96, a4, 1

    # A branch with both operands forwarded, from different stages: a7's
    # producer is in MEM and a6's is in WB when the branch reaches EX.
    li   a5, 7
    addi a6, a5, 0
    addi a7, a5, 0
    beq  a6, a7, 3f
    j    fail
3:  li   a5, 9
    addi a6, a5, 0
    addi a7, a5, 1              # deliberately unequal
    bne  a6, a7, 4f
    j    fail
4:  CHECK 97, a7, 10

    # -------------------------------------------------------- jal / jalr
    # jal must both land on the target and leave pc+4 in rd.
    li   a2, 0
    jal  ra, jal_target
jal_return:
    CHECK 80, a2, 1             # the target actually ran
    la   a4, jal_return
    CHECK_REG 81, ra, a4        # link register is the instruction after the jal

    # jalr must clear bit 0 of the computed target. Feeding it a deliberately
    # odd address is the only way to catch a missing mask.
    li   a2, 0
    la   a5, jalr_target
    addi a5, a5, 1              # make the target odd on purpose
    jalr ra, a5, 0
jalr_return:
    CHECK 82, a2, 1             # landed despite the odd bit
    la   a4, jalr_return
    CHECK_REG 83, ra, a4

    # -------------------------------------------------------- finished
    li   t0, 999
    li   t1, check_count
    bne  s0, t1, fail           # every check must have executed

pass:
    slti x0, x0, -256
    j    pass

jal_target:
    addi a2, a2, 1
    jalr zero, ra, 0            # return via jalr

jalr_target:
    addi a2, a2, 1
    jalr zero, ra, 0

hz_target:
    addi a2, a2, 1
    jalr zero, ra, 0

fail:
    j    fail

.section ".data"
.align 2
scratch:
    .word 0
    .word 0
