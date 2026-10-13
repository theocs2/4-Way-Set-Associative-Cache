module tb_wrapper;
    time clock_period_ps, clock_half_period_ps;

    bit clk = 1'b0;
    bit rst = 1'b1;
    bit dump_fsdb = 1'b0;

    int unsigned sim_timeout;

    initial begin
        if (!$value$plusargs("CLOCK_PERIOD_PS=%d", clock_period_ps)) begin
            $fatal(1, "ERROR: CLOCK_PERIOD_PS plusarg not defined.");
        end

        if (clock_period_ps < 2) begin
            $fatal(1, "ERROR: CLOCK_PERIOD_PS must be >= 2 ps (got %0d).", clock_period_ps);
        end

        clock_half_period_ps = clock_period_ps / 2;
        if (clock_half_period_ps == 0) begin
            $fatal(1, "ERROR: Computed clock half period is 0 ps.");
        end

        if (!$value$plusargs("SIM_TIMEOUT=%d", sim_timeout)) begin
            $fatal(1, "ERROR: SIM_TIMEOUT plusarg not defined.");
        end

        if (sim_timeout == 0) begin
            $fatal(1, "ERROR: SIM_TIMEOUT must be > 0.");
        end

        if (!$value$plusargs("DUMP_FSDB=%d", dump_fsdb)) begin
            $fatal(1, "ERROR: DUMP_FSDB plusarg not defined.");
        end

        $display("INFO: SIM_TIMEOUT=%0d cycles.", sim_timeout);
    end

    // Clock generator
    initial begin
        wait (clock_half_period_ps > 0);
        forever #(clock_half_period_ps) clk = ~clk;
    end

    // FSDB dumping + reset
    initial begin
        $fsdbDumpfile("dump.fsdb");

        if (dump_fsdb) begin
            $fsdbDumpvars(0, "+all");
            $fsdbDumpon();
        end else begin
            $fsdbDumpoff();
        end

        repeat (2) @(posedge clk);
        rst <= 1'b0;
    end

    // Timeout watchdog
    initial begin
        wait (clock_half_period_ps > 0);
        repeat (sim_timeout) @(posedge clk);
        $fatal(1, "ERROR: Simulation timeout after %0d cycles.", sim_timeout);
    end

    `include `TB_FILE
endmodule
