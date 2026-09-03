/* Places a bare-metal RV32 image inside the simulator's flat memory window.
 *
 * `_mem_base` and `_mem_size` are supplied on the link command line by
 * bin/generate_memory_file.py, which reads them from options.json so the
 * memory map is described in exactly one place.
 *
 * Symbols exported to bin/startup.s:
 *   _bss_start / _bss_end   region to zero before entering main()
 *   _stack_top              initial sp, top of the modelled memory
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = _mem_base;

    /* The reset stub lands first so the reset PC is the entry point. */
    .init : ALIGN(4)
    {
        KEEP(*(.init))
    }

    .text : ALIGN(4)
    {
        *(.text .text.*)
    }

    .rodata : ALIGN(4)
    {
        *(.rodata .rodata.* .srodata .srodata.*)
    }

    .data : ALIGN(4)
    {
        *(.data .data.* .sdata .sdata.*)
    }

    /* NOLOAD keeps .bss out of the memory image; startup.s zeroes it instead. */
    .bss (NOLOAD) : ALIGN(4)
    {
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    }

    _end = .;

    /* Defined for anything that references it; unused while linking --no-relax. */
    __global_pointer$ = _end;

    _stack_top = _mem_base + _mem_size;

    /DISCARD/ :
    {
        *(.eh_frame*)
        *(.riscv.attributes)
        *(.comment)
        *(.debug*)
    }
}
