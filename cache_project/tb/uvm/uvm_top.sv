module uvm_top;
    logic clk = 0;
    always #5 clk = ~clk;

    cache_if cpu_if(clk);

    cache dut (
        .clk      (clk),
        .rst      (cpu_if.rst),
        .ufp_addr (cpu_if.addr),
        .ufp_rdata(cpu_if.rdata),
        .ufp_wdata(cpu_if.wdata),
        .ufp_rmask(cpu_if.rmask),
        .ufp_wmask(cpu_if.wmask),
        .ufp_resp (cpu_if.resp)
    );

    initial begin
        uvm_config_db#(virtual cache_if)::set(
            null, "*", "vif", cpu_if
        );
        run_test("cache_test");
    end
endmodule