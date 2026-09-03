# Reset stub for C programs: put the machine into a known state, clear .bss,
# establish a stack, and enter main().
#
# Hand-written tests under testcode/ define their own _start and are assembled
# without this file, so nothing here needs to be test-aware.

    .section .init, "ax"
    .globl  _start
    .type   _start, @function

_start:
    # Registers power up undefined in the RTL. Zeroing them makes a program
    # that reads an uninitialised register fail identically on every run
    # instead of depending on whatever the previous test left behind.
    .irp reg, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\reg, 0
    .endr

    # Zero .bss a word at a time. The linker script aligns both bounds to 4,
    # so the region is always a whole number of words.
    la      t0, _bss_start
    la      t1, _bss_end
.Lbss_loop:
    bgeu    t0, t1, .Lbss_done
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       .Lbss_loop
.Lbss_done:

    la      sp, _stack_top
    mv      s0, sp

.option push
.option norelax
    la      gp, __global_pointer$
.option pop

    call    main

    # main() returned: stop the simulation. The testbench watches for this
    # encoding (slti x0, x0, -256) and finishes as soon as it is fetched.
    .globl  _halt
_halt:
    slti    x0, x0, -256
.Lspin:
    j       .Lspin

    .size   _start, . - _start
