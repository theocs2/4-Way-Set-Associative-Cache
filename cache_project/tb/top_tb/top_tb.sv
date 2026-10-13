
    logic [31:0] ufp_addr, ufp_rdata, ufp_wdata;
    logic [3:0] ufp_rmask, ufp_wmask;
    logic ufp_resp;
    logic [31:0] dfp_addr;
    logic dfp_read, dfp_write, dfp_resp;
    logic [255:0] dfp_rdata, dfp_wdata;

    cache dut (.*);

    localparam int WORDS = 8192;
    logic [31:0] memory [0:WORDS-1];
    logic [31:0] expected [0:WORDS-1];
    integer memory_reads, memory_writes;

    function automatic [31:0] line_addr(input integer tag, input integer set);
        line_addr = tag * 32'd512 + set * 32'd32;
    endfunction

    function automatic [31:0] mask_word(input logic [3:0] mask);
        mask_word = {{8{mask[3]}}, {8{mask[2]}},
                     {8{mask[1]}}, {8{mask[0]}}};
    endfunction

    covergroup cg @(posedge clk);
        state : coverpoint dut.current_cache_state iff(!rst) {
            bins idle = {types::IDLE};
            bins hit = {types::HIT};
            bins allocate = {types::ALLOCATE};
            bins writeback = {types::WRITEBACK};

            bins dirty_miss = (types::HIT => types::WRITEBACK => types::ALLOCATE);
            bins clean_miss = (types::HIT => types::ALLOCATE);
        }

        set_index : coverpoint dut.ufp_addr[8:5] iff(!rst && ((|ufp_rmask) || (|ufp_wmask))) {
            bins each_set [] = {[0:15]};
        }

        memory_cmds : coverpoint {dfp_read, dfp_write} iff(!rst) {
            bins write = {2'b01};
            bins read = {2'b10};
            illegal_bins both = {2'b11}; //**important so no simultaneous reads/writes to backing memory
        }

    endgroup

    cg cache_cg = new();

    task automatic run_memory;
        logic [31:0] saved_addr;
        logic [255:0] saved_data;
        logic saved_write;
        integer i;
        integer word_index;
        begin
            dfp_resp = 1'b0;
            dfp_rdata = '0;
            memory_reads = 0;
            memory_writes = 0;
            for (i = 0; i < WORDS; i = i + 1) begin
                memory[i] = 32'hCAFE_0000 + i;
                expected[i] = memory[i];
            end

            forever begin
                @(posedge clk);
                if (!rst && (dfp_read || dfp_write)) begin
                    assert (!(dfp_read && dfp_write))
                        else $fatal(1, "DFP read and write asserted together");
                    assert (!$isunknown({dfp_addr, dfp_wdata}) &&
                            dfp_addr[4:0] == 5'b0 &&
                            (dfp_addr >> 2) + 7 < WORDS)
                        else $fatal(1, "Invalid DFP request: %h", dfp_addr);

                    saved_addr = dfp_addr;
                    saved_data = dfp_wdata;
                    saved_write = dfp_write;
                    if (saved_write)
                        memory_writes = memory_writes + 1;
                    else
                        memory_reads = memory_reads + 1;

                    // Keep the command and address stable for a variable delay.
                    repeat (2 + (memory_reads + memory_writes) % 3)
                        @(negedge clk);
                    assert (saved_write ? dfp_write : dfp_read)
                        else $fatal(1, "DFP command changed while pending");
                    assert (dfp_addr == saved_addr)
                        else $fatal(1, "DFP address changed while pending");

                    word_index = saved_addr >> 2;
                    if (!saved_write)
                        for (i = 0; i < 8; i = i + 1)
                            dfp_rdata[i*32 +: 32] = memory[word_index + i];
                    dfp_resp = 1'b1;
                    @(posedge clk);
                    if (saved_write)
                        for (i = 0; i < 8; i = i + 1)
                            memory[word_index + i] = saved_data[i*32 +: 32];
                    @(negedge clk);
                    dfp_resp = 1'b0;
                end
            end
        end
    endtask

    task automatic reset_cache;
        integer i;
        begin
            rst = 1'b1;
            ufp_addr = '0;
            ufp_wdata = '0;
            ufp_rmask = '0;
            ufp_wmask = '0;
            for (i = 0; i < WORDS; i = i + 1) begin
                memory[i] = 32'hCAFE_0000 + i;
                expected[i] = memory[i];
            end
            repeat (4) @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic cpu_access(input logic [31:0] addr,
                               input logic write_request,
                               input logic [3:0] byte_mask,
                               input logic [31:0] data);
        logic completed;
        logic [31:0] word_mask;
        integer cycles;
        integer byte_number;
        begin
            completed = 1'b0;
            word_mask = mask_word(byte_mask);
            @(negedge clk);
            ufp_addr = addr;
            ufp_wdata = data;
            ufp_rmask = write_request ? 4'b0 : byte_mask;
            ufp_wmask = write_request ? byte_mask : 4'b0;
            @(posedge clk);
            for (cycles = 0; cycles < 200; cycles = cycles + 1) begin
                @(posedge clk);
                if (ufp_resp === 1'b1) begin
                    if (write_request) begin
                        for (byte_number = 0; byte_number < 4; byte_number = byte_number + 1)
                            if (byte_mask[byte_number])
                                expected[addr >> 2][byte_number*8 +: 8] =
                                    data[byte_number*8 +: 8];
                    end else begin
                        assert ((ufp_rdata & word_mask) ===
                                (expected[addr >> 2] & word_mask))
                            else $fatal(1, "Read %h: got %h expected %h mask %h",
                                        addr, ufp_rdata, expected[addr >> 2], byte_mask);
                    end
                    completed = 1'b1;
                    break;
                end
            end
            assert (completed) else $fatal(1, "No CPU response for %h", addr);
            @(negedge clk);
            ufp_rmask = '0;
            ufp_wmask = '0;
        end
    endtask

    initial run_memory();


    logic [31:0] last_wb_addr;

    always @(posedge clk) //runs at EVERY clock edge
        if(dfp_write && dfp_resp) last_wb_addr <= dfp_addr; 

    initial begin
        integer tag;
        integer word;
        integer writes_before, reads_before;
        logic [31:0] addr;
        logic [31:0] random_data;
        logic [3:0] random_mask, random_mask_total;
        logic random_write;
        integer base;
        integer set_idx;
        
        


        reset_cache();

        // Cold miss, hit, all word offsets, and partial-byte writes.
        for (word = 0; word < 8; word = word + 1) begin
            addr = line_addr(0, 15) + word * 4;
            cpu_access(addr, 1'b0, 4'hf, 0);
            cpu_access(addr, 1'b1, 4'b0001 << (word % 4),
                       32'hA500_0000 + word);
            cpu_access(addr, 1'b0, 4'hf, 0);
        end

        // Fill all four ways in one set and dirty each line.
        for (tag = 1; tag < 5; tag = tag + 1) begin
            addr = line_addr(tag, 15) + 4;
            cpu_access(addr, 1'b0, 4'hf, 0);
            cpu_access(addr, 1'b1, 4'hf, 32'hD000_0000 + tag);
        end

        // A fifth tag must cause a PLRU-selected dirty writeback.
        writes_before = memory_writes;
        cpu_access(line_addr(5, 15), 1'b0, 4'hf, 0);
        assert (memory_writes == writes_before + 1)
            else $fatal(1, "Dirty eviction did not generate exactly one writeback (before=%0d after=%0d)",
                        writes_before, memory_writes);

        // Every line must remain architecturally correct after replacement.
        for (tag = 0; tag < 6; tag = tag + 1)
            for (word = 0; word < 8; word = word + 1)
                cpu_access(line_addr(tag, 15) + word * 4, 1'b0, 4'hf, 0);

        // Random conflicts: eight tags competing for the four ways in set 15.
        repeat (200) begin
            if (!std::randomize(addr, random_data, random_mask, random_write) with {
                addr[8:5] == 4'hf;
                addr[1:0] == '0;
                addr < 32'd32768;

                
                random_mask inside {[1:15]};
            }) $fatal(1, "Set-15 randomization failed");

            cpu_access(addr, random_write, random_mask, random_data);
            // Check all bytes, including bytes a partial write should preserve.
            cpu_access(addr, 1'b0, 4'hf, 0);
        end


        
        

        //test pLRU. fill w0, w1, w2, w3, write, check if w0 was evicted
        repeat(500) begin
            base = $urandom_range(0, 59);
            set_idx = $urandom_range(0, 15);

            for(tag = 0; tag < 4; tag++) begin
                cpu_access(line_addr(base + tag, set_idx), 1'b1, 4'hf, $urandom); //dirties all ways
            end

            writes_before = memory_writes;
            cpu_access(line_addr(base + 4, set_idx), 1'b1, 4'hf, $urandom); //write into cache, w0 should be evicted
            assert(memory_writes == writes_before + 1)
                else $fatal(1, "failed plru line 232 test");
            assert(last_wb_addr == line_addr(base + 0, set_idx))
                else $fatal(1, "evicted WRONG line during plru test line 232");
        end

        repeat(200) begin
            if(!std::randomize(addr, random_data, random_mask, random_write) with {
                addr[1:0] == '0;
                addr < 32'd4096;

                random_mask dist {4'b1111 := 75, [1:14] :/ 25};
            }) $fatal(1, "randomization failed");

            cpu_access(addr, random_write, random_mask, random_data);
        end

        // Broaden to all sets, keeping eight possible tags per set.
        repeat (500) begin
            if (!std::randomize(addr, random_data, random_mask, random_write) with {
                addr < 32'd4096;
                addr[1:0] == 2'b00;
                random_mask inside {[1:15]};
            }) $fatal(1, "All-set randomization failed");

            cpu_access(addr, random_write, random_mask, random_data);
            cpu_access(addr, 1'b0, 4'hf, 0);
        end


        //simple pLRU testing
        reset_cache();

        for(integer set = 0; set < 4; set++) begin
            cpu_access(addr, random_write, random_mask, random_data); 
        end


        // Revisit the full randomized address range to check data after eviction.
        for (integer word = 0; word < 1024; word = word + 1)
            cpu_access(32'(word * 4), 1'b0, 4'hf, 0);

        assert (memory_reads > 0 && memory_writes > 0)
            else $fatal(1, "Memory traffic did not exercise both directions");
        $display("PASS: cache directed + random test, memory reads=%0d writes=%0d",
                 memory_reads, memory_writes);
        $finish;
    end