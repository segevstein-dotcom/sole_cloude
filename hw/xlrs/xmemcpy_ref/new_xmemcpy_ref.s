import xbox_def_pkg::*;

module xmemcpy_ref (
  input        clk,
  input        rst_n,  
 
  input        [XBOX_NUM_REGS-1:0][31:0] host_regs,
  input  logic [XBOX_NUM_REGS-1:0]       host_regs_valid_pulse,
  output logic [XBOX_NUM_REGS-1:0][31:0] host_regs_data_out,
  output logic [XBOX_NUM_REGS-1:0]       host_regs_valid_out,
  input  logic [XBOX_NUM_REGS-1:0]       host_regs_read_pulse,

  mem_intf_read.client_read   mem_intf_read,
  mem_intf_write.client_write mem_intf_write 
 );
 
  logic [XMEM_ADDR_WIDTH-1:0] xmem_src_addr; 
  logic [XMEM_ADDR_WIDTH-1:0] xmem_dst_addr;
  logic [31:0] len_bytes;
  logic        start_copy;
  logic        copy_done;
  logic        clear_done_on_read;

  logic [XMEM_ADDR_WIDTH-1:0] crnt_rd_addr;
  logic [XMEM_ADDR_WIDTH-1:0] crnt_wr_addr;
  
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] mem_data;
         
  enum {IDLE, READ, WRITE, DONE} next_state, state;
   
  logic [31:0] remaining_size;
  logic [5:0]  crnt_size;
  logic [5:0]  first_size;
  logic        is_last;

  enum {
     XMEM_SRC_ADDR_REG_IDX = 0, 
     XMEM_DST_ADDR_REG_IDX = 1,
     COPY_LEN_REG_IDX      = 2, 
     COPY_START_REG_IDX    = 3, 
     COPY_DONE_REG_IDX     = 4 
  } regs_idx;

  // Host regs interface
  logic [XBOX_NUM_REGS-1:0][31:0] host_regs_data_out_ps;

  always_comb begin
   host_regs_data_out_ps = host_regs_data_out;

   if (copy_done)
     host_regs_data_out_ps[COPY_DONE_REG_IDX][0] = 1;
   else if (host_regs_read_pulse == (1 << COPY_DONE_REG_IDX))
     host_regs_data_out_ps[COPY_DONE_REG_IDX][0] = 0;
  end 
  
  always @(posedge clk, negedge rst_n) begin
     if (~rst_n)
       host_regs_data_out <= 0;
     else
       host_regs_data_out <= host_regs_data_out_ps;        
  end
  
  always_comb begin
   host_regs_valid_out = 0;
   host_regs_valid_out[COPY_DONE_REG_IDX] =
     host_regs_data_out[COPY_DONE_REG_IDX][0];
  end
  
  assign xmem_src_addr      = host_regs[XMEM_SRC_ADDR_REG_IDX][XMEM_ADDR_WIDTH-1:0];
  assign xmem_dst_addr      = host_regs[XMEM_DST_ADDR_REG_IDX][XMEM_ADDR_WIDTH-1:0];
  assign len_bytes          = host_regs[COPY_LEN_REG_IDX];
  assign start_copy         = host_regs[COPY_START_REG_IDX] &&
                              host_regs_valid_pulse[COPY_START_REG_IDX];
  assign clear_done_on_read = host_regs_read_pulse[COPY_DONE_REG_IDX];

  // Current access size
  assign crnt_size =
    (remaining_size >= BYTES_PER_XMEM_LINE) ?
    BYTES_PER_XMEM_LINE[$clog2(BYTES_PER_XMEM_LINE):0] :
    remaining_size[$clog2(BYTES_PER_XMEM_LINE):0];

  // First block size, needed at start_copy
  assign first_size =
    (len_bytes >= BYTES_PER_XMEM_LINE) ?
    BYTES_PER_XMEM_LINE[$clog2(BYTES_PER_XMEM_LINE):0] :
    len_bytes[$clog2(BYTES_PER_XMEM_LINE):0];

  // Last transaction is when remaining data fits in current write
  assign is_last = (state == WRITE) && (remaining_size <= BYTES_PER_XMEM_LINE);

  // State machine comb
  always_comb begin
   next_state = state; 

   mem_intf_write.mem_size_bytes = crnt_size;   
   mem_intf_read.mem_size_bytes  = crnt_size;

   mem_intf_write.mem_data       = mem_data; 
   mem_intf_write.mem_start_addr = crnt_wr_addr;   
   mem_intf_read.mem_start_addr  = crnt_rd_addr;  

   mem_intf_read.mem_req  = 0;
   mem_intf_write.mem_req = 0;   
   copy_done = 0;  
      
   case (state)
   
      IDLE: begin
        if (start_copy)
          next_state = READ;
      end          
      
      READ: begin
        mem_intf_read.mem_req = 1;

        if (mem_intf_read.mem_valid) begin
          next_state = WRITE; 
          mem_intf_read.mem_req = 0;
        end 
      end 

      WRITE: begin
        mem_intf_write.mem_req = 1;

        if (mem_intf_write.mem_ack) begin
          next_state = is_last ? DONE : READ;
          mem_intf_write.mem_req = 0;          
        end
      end 

      DONE: begin
        copy_done = 1;

        if (clear_done_on_read)
          next_state = IDLE; 
      end 
 
   endcase
  end

  // State register
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      state <= IDLE;
    else
      state <= next_state;
  end

  // Main sequential logic
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin 

      remaining_size <= 0;
      crnt_rd_addr   <= 0;  
      crnt_wr_addr   <= 0;
      mem_data       <= 0;
      
    end else begin 
    
      if (start_copy) begin

        crnt_rd_addr   <= xmem_src_addr;

        // Start writing from the last destination block
        crnt_wr_addr   <= xmem_dst_addr + len_bytes - first_size;

        remaining_size <= len_bytes;

      end else begin
      
        // Keep data order inside each block unchanged
        if (mem_intf_read.mem_valid)
          mem_data <= mem_intf_read.mem_data;
    
        // Read source forward
        if (mem_intf_read.mem_valid)
          crnt_rd_addr <= crnt_rd_addr + crnt_size;
                  
        if (mem_intf_write.mem_ack) begin

          // Write destination backward by blocks
          crnt_wr_addr <= crnt_wr_addr - crnt_size;

          remaining_size <= remaining_size - crnt_size; 
        end          
      end 
    end 
  end 

endmodule