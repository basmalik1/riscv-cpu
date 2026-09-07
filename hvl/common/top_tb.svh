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
        .commit     (core_commit)
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
                $fatal(1, "TB Error: stopping, memory reported an error (see above)");
            end
            if (core_commit) begin
                retired <= retired + 1;
            end
            if (core_halt) begin
                $display("TB Info: halt after %0d cycles, %0d retired, IPC %0d.%03d",
                         cycles, retired,
                         retired / (cycles == 0 ? 1 : cycles),
                         ((retired * 1000) / (cycles == 0 ? 1 : cycles)) % 1000);
                $finish;
            end
            if (cycles >= timeout) begin
                $fatal(1, "TB Error: timed out after %0d cycles", cycles);
            end
            cycles <= cycles + 1;
        end
    end
