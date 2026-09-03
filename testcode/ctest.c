/* Exercises the C build path: bin/startup.s (register zeroing, .bss clearing,
 * stack setup) and bin/link.ld section placement. Assembly tests define their
 * own _start and are linked without startup.s, so this is the only coverage
 * either file gets.
 *
 * Same convention as smoke.s: spin forever on a mismatch so a failure shows up
 * as a testbench timeout, and return normally so startup.s runs the halt
 * instruction on success.
 */

int bss_word;                       /* .bss  -- startup.s must zero this   */
int data_word = 0x12345678;         /* .data -- must survive the image load */

volatile int bss_array[8];          /* .bss  -- a region, not just a word  */

static void fail(void)
{
    for (;;) {
        __asm__ volatile ("");      /* keep the loop from being optimised away */
    }
}

/* volatile locals force real stack slots, so this fails if _stack_top does not
 * point at usable memory. noinline stops the whole thing folding to a constant. */
int __attribute__((noinline)) stack_probe(int n)
{
    volatile int local[4];

    local[0] = n;
    local[1] = n + 1;
    local[2] = n + 2;
    local[3] = n + 3;

    return local[0] + local[1] + local[2] + local[3];
}

int main(void)
{
    if (bss_word != 0) {
        fail();                     /* .bss was not cleared */
    }

    if (data_word != 0x12345678) {
        fail();                     /* .data did not load from the image */
    }

    for (int i = 0; i < 8; i++) {
        if (bss_array[i] != 0) {
            fail();                 /* .bss cleared incompletely */
        }
    }

    if (stack_probe(1) != 10) {
        fail();                     /* stack is unusable */
    }

    /* Writes to .data must stick. */
    data_word = 0x0badc0de;
    if (data_word != 0x0badc0de) {
        fail();
    }

    return 0;
}
