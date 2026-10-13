interface cache_if(input logic clk);
    logic rst;
    logic [31:0] addr;
    logic [31:0] rdata;
    logic [31:0] wdata;
    logic [3:0]  rmask;
    logic [3:0]  wmask;
    logic        resp;
endinterface