// Shared testbench body, included by each simulator's top_tb wrapper.
// Expects MEM_BASE / MEM_SIZE parameters and clk / rst ports in scope.

    longint timeout;
    longint cycles;

    initial begin
        if (!$value$plusargs("TIMEOUT=%d", timeout)) begin
            $fatal(1, "TB Error: +TIMEOUT=<cycles> was not provided");
        end
        cycles = 0;
        retired = 0;
    end

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_rmask, dmem_wmask;
    logic        mem_error;
    logic        core_halt;
    logic        core_commit;
    longint      retired;

    logic [31:0] commit_pc;
    logic        commit_regf_we;
    logic [4:0]  commit_rd_s;
    logic [31:0] commit_rd_v;

    cpu #(
        .RESET_PC   (MEM_BASE)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_rmask (dmem_rmask),
        .dmem_wmask (dmem_wmask),
        .dmem_rdata (dmem_rdata),
        .halt       (core_halt),
        .commit     (core_commit),
        .commit_pc      (commit_pc),
        .commit_regf_we (commit_regf_we),
        .commit_rd_s    (commit_rd_s),
        .commit_rd_v    (commit_rd_v)
    );

    // SYNC_MEM comes from the build: the single-cycle core needs a
    // combinational read, the pipelined core needs a registered one.
    generate
    if (SYNC_MEM != 0) begin : g_mem
    sync_memory #(
        .MEM_BASE   (MEM_BASE),
        .MEM_SIZE   (MEM_SIZE)
    ) mem (
        .clk        (clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_rmask (dmem_rmask),
        .dmem_wmask (dmem_wmask),
        .dmem_rdata (dmem_rdata),
        .error      (mem_error)
    );
    end else begin : g_mem
    magic_memory #(
        .MEM_BASE   (MEM_BASE),
        .MEM_SIZE   (MEM_SIZE)
    ) mem (
        .clk        (clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_rmask (dmem_rmask),
        .dmem_wmask (dmem_wmask),
        .dmem_rdata (dmem_rdata),
        .error      (mem_error)
    );
    end
    endgenerate

    // ------------------------------------------------------------------
    // commit trace
    // ------------------------------------------------------------------
    // Written only when +COMMITLOG=<path> is given, so an ordinary run pays
    // nothing for it. One line per retired instruction:
    //
    //     <pc> <inst> x<rd> <value>     a register was written
    //     <pc> <inst> -                 nothing was written
    //
    // The instruction word is read back out of the memory image rather than
    // carried through the core. Nothing here self-modifies, so the word at the
    // committed PC is the word that executed.
    //
    // A write to x0 is logged as no write. The register file discards it and
    // so does the ISA, so calling it a write would be a difference from the
    // golden model that is not a difference in behaviour.
    int    commit_fd = 0;
    string commit_path;

    initial begin
        if ($value$plusargs("COMMITLOG=%s", commit_path)) begin
            commit_fd = $fopen(commit_path, "w");
            if (commit_fd == 0) begin
                $fatal(1, "TB Error: cannot open commit log '%s'", commit_path);
            end
        end
    end

    function automatic logic [31:0] word_at(logic [31:0] addr);
        if (addr < MEM_BASE || addr >= MEM_BASE + 32'(MEM_SIZE)) begin
            // Out of range means the core fetched somewhere it should not
            // have. Log a value that cannot be mistaken for an instruction
            // rather than reading past the array; the PC mismatch is what the
            // comparator will report anyway.
            word_at = 32'hxxxx_xxxx;
        end else begin
            word_at = g_mem.mem.ram[(addr - MEM_BASE) >> 2];
        end
    endfunction

    // Called on every exit path, not just the successful one. A run that
    // times out or faults is precisely the run whose trace is worth reading,
    // and an unclosed file loses the tail that says where it went wrong.
    task automatic close_trace();
        // No guard against a second call and none needed: every caller exits
        // the simulation on the next line. Clearing commit_fd here would be a
        // blocking assignment inside a sequential process, which is a warning
        // for a good reason and not worth waiving for a variable nothing reads
        // again.
        if (commit_fd != 0) begin
            $fclose(commit_fd);
        end
    endtask

    task automatic trace_commit();
        logic [31:0] inst;
        inst = word_at(commit_pc);
        if (commit_regf_we && commit_rd_s != 5'd0) begin
            $fdisplay(commit_fd, "%08h %08h x%0d %08h",
                      commit_pc, inst, commit_rd_s, commit_rd_v);
        end else begin
            $fdisplay(commit_fd, "%08h %08h -", commit_pc, inst);
        end
    endtask

    // Single place that decides how a run ends. Components below report what went
    // wrong via $display and raise a sticky flag; this block turns that into a
    // simulator-independent stop. mem_error is registered inside the memory, so
    // it lands here one cycle after the offending access -- which also means the
    // failing cycle is already in the waveform when the run ends.
    always @(posedge clk) begin
        if (!rst) begin
            // Checked before halt so a faulting access cannot be masked by a
            // program that happens to halt on the same cycle.
            if (mem_error) begin
                close_trace();
                $fatal(1, "TB Error: stopping, memory reported an error (see above)");
            end
            if (core_commit) begin
                retired <= retired + 1;
                if (commit_fd != 0) begin
                    trace_commit();
                end
            end
            if (core_halt) begin
                $display("TB Info: halt after %0d cycles, %0d retired, IPC %0d.%03d",
                         cycles, retired,
                         retired / (cycles == 0 ? 1 : cycles),
                         ((retired * 1000) / (cycles == 0 ? 1 : cycles)) % 1000);
                close_trace();
                $finish;
            end
            if (cycles >= timeout) begin
                close_trace();
                $fatal(1, "TB Error: timed out after %0d cycles", cycles);
            end
            cycles <= cycles + 1;
        end
    end
