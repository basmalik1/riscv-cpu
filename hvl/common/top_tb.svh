// Shared testbench body, included by each simulator's top_tb wrapper.
// Expects MEM_BASE / MEM_SIZE parameters and clk / rst ports in scope.

    longint timeout;
    longint cycles;

    initial begin
        if (!$value$plusargs("TIMEOUT=%d", timeout)) begin
            $fatal(1, "TB Error: +TIMEOUT=<cycles> was not provided");
        end
        cycles = 0;
    end

    logic [31:0] imem_addr, imem_rdata;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_rmask, dmem_wmask;
    logic        mem_error;

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
        .dmem_rdata (dmem_rdata)
    );

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
            if (imem_rdata == rv32i_types::HALT_INST) begin
                $display("TB Info: halt reached at pc=%h after %0d cycles", imem_addr, cycles);
                $finish;
            end
            if (cycles >= timeout) begin
                $fatal(1, "TB Error: timed out after %0d cycles", cycles);
            end
            cycles <= cycles + 1;
        end
    end
