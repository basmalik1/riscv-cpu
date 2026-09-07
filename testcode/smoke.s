# Arithmetic, branches, and a store/load round trip.
#
# Every check folds its result into a running signature in s0, and the halt at
# the end is guarded by a branch comparing that signature against a constant.
# So reaching halt requires having executed each step AND gotten the right
# answer -- not merely having walked far enough. The fail loop sits between the
# guard and the halt, so a guard that does not fire lands in the loop and shows
# up as a testbench timeout.
#
# Residual gap, stated plainly: a core that ignores control flow entirely still
# reaches the halt, because it linearly executes every word in the image
# including this one. Program layout cannot defend against that -- closing it
# needs a testbench-side check (a signature write the TB verifies, or Spike
# lockstep). See docs/roadmap.md.

.section ".init"
.globl _start
_start:
    li   s0, 0                  # running signature

    # --- add -------------------------------------------------------------
    li   t0, 5
    li   t1, 7
    add  t2, t0, t1             # 12
    li   t3, 12
    bne  t2, t3, fail
    add  s0, s0, t2             # sig = 12

    # --- sub -------------------------------------------------------------
    sub  t4, t2, t0             # 7
    bne  t4, t1, fail
    add  s0, s0, t4             # sig = 19

    # --- shift left ------------------------------------------------------
    slli t5, t1, 2              # 28
    li   t6, 28
    bne  t5, t6, fail
    add  s0, s0, t5             # sig = 47

    # --- store / load round trip -----------------------------------------
    la   a0, scratch
    sw   t2, 0(a0)
    lw   a1, 0(a0)
    bne  a1, t3, fail
    add  s0, s0, a1             # sig = 59

    # --- guard: only a correct signature reaches the halt ----------------
    li   a2, 59
    beq  s0, a2, pass

fail:
    j    fail

pass:
    slti x0, x0, -256           # halt
    j    pass

.section ".data"
.align 2
scratch:
    .word 0
