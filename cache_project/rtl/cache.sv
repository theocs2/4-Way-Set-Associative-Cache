module cache (
    input   logic           clk,
    input   logic           rst,

    // cpu side signals, ufp -> upward facing port
    input   logic   [31:0]  ufp_addr,
    input   logic   [3:0]   ufp_rmask,
    input   logic   [3:0]   ufp_wmask,
    output  logic   [31:0]  ufp_rdata, //32-bit CPU data port
    input   logic   [31:0]  ufp_wdata,
    output  logic           ufp_resp,

    // memory side signals, dfp -> downward facing port
    output  logic   [31:0]  dfp_addr,
    output  logic           dfp_read,
    output  logic           dfp_write,
    input   logic   [255:0] dfp_rdata, //data on MEMORY SIDE
    output  logic   [255:0] dfp_wdata,
    input   logic           dfp_resp
);
    import types::*;
    cache_state_t current_cache_state, next_cache_state;
    logic allocation_wait;


    logic [31:0] request_addr; //register all data inputs so we don't lose them if signal goes low
    logic [3:0] request_rmask;
    logic [3:0] request_wmask;
    logic [31:0] request_wdata;

    logic [22:0] request_tag;
    logic [3:0] request_set;
    logic [4:0] request_offset;

    // way array outputs
    logic [255:0] data_out [4]; //cache output. 256 bits each, 4 ways
    logic [22:0] tag_out [4];
    logic [3:0] valid_out, dirty_out;
    logic valid_in; //valid input signal


    // active-low write enable array bits
    logic [3:0] data_web, tag_web, valid_web, dirty_web;

    //Write inputs
    logic [255:0]   data_in;
    logic [31:0]    data_wmask;
    logic           dirty_in;

    // Start the SRAM lookup while capturing the incoming request.
    logic [3:0] array_set;
    assign array_set = (current_cache_state == IDLE) ? ufp_addr[8:5] : request_set;

    //Hit detection/replacement
    logic [3:0] hit_vec; //check each of ways for a hit (4 ways)
    logic hit;
    logic [1:0] hit_way; //which way (0-3) was hit a part of?



    //pLRU array controls
    logic lru_web;
    logic [2:0] plru_in, plru_out;



    assign request_tag = request_addr[31:9];
    assign request_set = request_addr[8:5];
    assign request_offset = request_addr[4:0];


    //victim signals
    logic [1:0] victim_way; //which way is victim a part of?
    logic [22:0] victim_tag;
    logic [255:0] victim_data;
    logic victim_valid;
    logic victim_dirty;

    assign victim_tag  = tag_out[victim_way];
    assign victim_data  = data_out[victim_way];
    assign victim_valid = valid_out[victim_way];
    assign victim_dirty = dirty_out[victim_way];



    always_comb begin
        next_cache_state = current_cache_state;

        ufp_resp = 1'b0;
        ufp_rdata = '0;
        dfp_read = 1'b0;
        dfp_write = 1'b0;
        dfp_addr = {request_tag, request_set, 5'b0};
        dfp_wdata = '0;

        data_web = '1;
        tag_web = '1;
        valid_web = '1;
        dirty_web = '1;
        data_in = '0;
        data_wmask = '0;
        valid_in = 1'b1;
        dirty_in = 1'b0;
        lru_web = 1'b1;
        case(current_cache_state)

        IDLE: begin //IDLE state. Wait for mask inputs to indicate requested cache function.
            if(allocation_wait) begin
                next_cache_state = HIT;
            end
            else if(|ufp_rmask || |ufp_wmask) begin
                next_cache_state = HIT; //else stay idle
            end
        end

        HIT: begin //Check for a hit.
            // The SRAM write from an allocation becomes visible one clock later.
                if(hit) begin
                next_cache_state = IDLE; //hit confirmed

                ufp_resp = 1'b1; // Complete the CPU request.
                lru_web = 1'b0;

                if(|request_rmask) begin
                    ufp_rdata = data_out[hit_way][32 * request_offset[4:2] +: 32]; //reads 1 word from the desired way upon a hit
                end


                if(|request_wmask) begin
                    data_web[hit_way] = 1'b0; //active low enable
                    data_in[32 * request_offset[4:2] +: 32] = request_wdata;
                    data_wmask[4 * request_offset[4:2] +: 4] = request_wmask;

                    dirty_web[hit_way] = 1'b0;
                    dirty_in = 1'b1;
                end



            end else if(victim_valid && victim_dirty) begin
                next_cache_state = WRITEBACK; //dirty miss
            end else begin
                next_cache_state = ALLOCATE; //clean miss
            end
        end

        WRITEBACK: begin //Miss occurred, result was valid/dirty, so we must write back to memory before reading value.
            if(dfp_resp) begin
                next_cache_state = ALLOCATE;
            end

            dfp_write = 1'b1;
            dfp_addr = {victim_tag, request_set, 5'b0};
            dfp_wdata = victim_data;

        end

        ALLOCATE: begin // Fetch the requested line after any required writeback.
            dfp_read = 1'b1; //read signal -> memory. since memory access time isn't guaranteed stay here until response received
            if(dfp_resp) begin
                data_in = dfp_rdata; //store value from memory into cache
                data_web[victim_way] = 1'b0; // Install the fetched line @ old victim's location
                data_wmask = '1;
                tag_web[victim_way] = 1'b0;
                valid_web[victim_way] = 1'b0;
                dirty_web[victim_way] = 1'b0;
                dirty_in = 1'b0;
                lru_web = 1'b0;

                // A write miss must be applied after the line is installed.
                next_cache_state = IDLE;
            end

        end

        default: begin
            next_cache_state = IDLE;
        end
        endcase
    end

    // hit detection logic: matching tag & valid
    // hit_vec = 0010 -> hit somewhere in way 1
    // ONE-HOT!
    always_comb begin
        hit_vec = 4'b0; //default
        hit_way = 2'b0;
        hit = 1'b0;

        for(integer way = 0; way < 4; way++) begin
            hit_vec[way] = valid_out[way] && (tag_out[way] == request_tag);

            if(hit_vec[way]) begin
                hit_way = way[1:0]; //encode which way was hit after hit_vec goes high
                hit = 1'b1;
            end
        end
    end

    always_comb begin
       if(plru_out[0] == 1'b0) begin //root points left
            victim_way = (plru_out[1] == 1'b0) ? 2'b00 : 2'b01;
       end else begin //root points right
            victim_way = (plru_out[2] == 1'b0) ? 2'b10 : 2'b11; //choose remaining ways based on direction
       end
    end

    // victim signals
    // logic [1:0] victim_way;
    // logic [22:0] victim_tag;
    // logic [255:0] victim_data;
    // logic victim_valid;
    // logic victim_dirty;

    //combinational block to update pLRU output
    always_comb begin
        plru_in = plru_out;

        case(hit ? hit_way : victim_way)
            2'b00: begin
                plru_in[0] = 1'b1;
                plru_in[1] = 1'b1;
            end

            2'b01: begin
                plru_in[0] = 1'b1;
                plru_in[1] = 1'b0;
            end

            2'b10: begin
                plru_in[0] = 1'b0;
                plru_in[2] = 1'b1;
            end

            2'b11: begin
                plru_in[0] = 1'b0;
                plru_in[2] = 1'b0;
            end

            default: begin end
        endcase
    end


    always_ff @(posedge clk) begin
        if(rst) begin
            current_cache_state <= IDLE;
            request_addr <= '0;
            request_rmask <= '0;
            request_wmask <= '0;
            request_wdata <= '0;
            allocation_wait <= 1'b0;
        end else begin
            current_cache_state <= next_cache_state;
            if (current_cache_state == IDLE &&
                (|ufp_rmask || |ufp_wmask)) begin
                request_addr <= ufp_addr;
                request_rmask <= ufp_rmask;
                request_wmask <= ufp_wmask;
                request_wdata <= ufp_wdata;
            end
            if (current_cache_state == ALLOCATE && dfp_resp)
                allocation_wait <= 1'b1;
            else if (current_cache_state == IDLE && allocation_wait)
                allocation_wait <= 1'b0;
        end
    end




    generate for (genvar i = 0; i < 4; i++) begin : arrays //creates array for each 4 ways
        mp_cache_data_array data_array ( //data array
            .clk0       (clk),
            .csb0       (1'b0),
            .web0       (data_web[i]),
            .wmask0     (data_wmask),
            .addr0      (array_set),
            .din0       (data_in),
            .dout0      (data_out[i])
        );
        mp_cache_tag_array tag_array ( //tag information for each cache line
            .clk0       (clk),
            .csb0       (1'b0),
            .web0       (tag_web[i]),
            .addr0      (array_set),
            .din0       (request_tag),
            .dout0      (tag_out[i])
        );
        sp_ff_array valid_array ( //metadata
            .clk0       (clk),
            .rst0       (rst),
            .csb0       (1'b0),
            .web0       (valid_web[i]),
            .addr0      (array_set),
            .din0       (valid_in),
            .dout0      (valid_out[i])
        );
        sp_ff_array dirty_array ( //metadata
            .clk0   (clk),
            .rst0   (rst),
            .csb0   (1'b0), //active LOW chip select bit
            .web0   (dirty_web[i]),
            .addr0  (array_set),
            .din0   (dirty_in),
            .dout0  (dirty_out[i])
);
    end endgenerate

    sp_ff_array #(
        .WIDTH      (3)
    ) lru_array (
        .clk0       (clk),
        .rst0       (rst),
        .csb0       (1'b0),
        .web0       (lru_web),
        .addr0      (array_set),
        .din0       (plru_in),
        .dout0      (plru_out)
    );

endmodule
