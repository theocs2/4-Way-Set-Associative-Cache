package types;
    typedef enum logic [1:0] {
        IDLE,
        HIT,
        WRITEBACK,
        ALLOCATE
    } cache_state_t;
endpackage : types