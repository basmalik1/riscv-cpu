# Smallest end-to-end test: arithmetic, a taken/not-taken branch, and a
# store/load round trip. Falls into an infinite loop on mismatch so a failure
# shows up as a testbench timeout rather than a silent pass.

.section ".init"
.globl _start
_start:
    li   t0, 5
    li   t1, 7
    add  t2, t0, t1             # t2 = 12
    li   t3, 12
    bne  t2, t3, fail

    sub  t4, t2, t0             # t4 = 7
    bne  t4, t1, fail

    slli t5, t1, 2              # t5 = 28
    li   t6, 28
    bne  t5, t6, fail

    la   a0, scratch
    sw   t2, 0(a0)
    lw   a1, 0(a0)
    bne  a1, t3, fail

pass:
    slti x0, x0, -256           # halt
    .rept 16
    nop
    .endr

fail:
    beq  zero, zero, fail

.section ".data"
.align 2
scratch:
    .word 0
