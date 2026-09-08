// Shared checking for the unit testbenches. Included at module scope.
//
// Every check is counted, and a failure records what was expected rather than
// stopping at the first one -- a stage with three broken cases is more useful
// to see whole than one case at a time.

    int checks_run    = 0;
    int checks_failed = 0;

    // A hang is worse than a failure. It looks like a stuck build rather than
    // a bug, and anything judging these tests from the outside -- CI, or the
    // mutation harness -- reads a timeout as "nothing was detected" when the
    // truth may be that the test detected plenty and then never got to say so.
    //
    // Deliberately generous: the longest test here runs a few tens of
    // thousands of cycles, so this only fires on a genuine loop.
    initial begin
        #50_000_000;
        $fatal(1, "watchdog expired after %0d checks -- the test hung", checks_run);
    end

    task automatic expect_eq(string what, logic [31:0] got, logic [31:0] want);
        checks_run = checks_run + 1;
        if (got !== want) begin
            checks_failed = checks_failed + 1;
            $display("  FAIL %-38s got %08h  want %08h", what, got, want);
        end
    endtask

    task automatic expect_bit(string what, logic got, logic want);
        checks_run = checks_run + 1;
        if (got !== want) begin
            checks_failed = checks_failed + 1;
            $display("  FAIL %-38s got %b  want %b", what, got, want);
        end
    endtask

    task automatic report(string name);
        if (checks_failed == 0) begin
            $display("PASS %-16s %0d checks", name, checks_run);
            $finish;
        end else begin
            $display("FAIL %-16s %0d of %0d checks failed",
                     name, checks_failed, checks_run);
            $fatal(1, "unit test failed");
        end
    endtask
