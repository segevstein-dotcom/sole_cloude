import xbox_def_pkg::*;
import slrx_def_pkg::*;

module linear (
  input   clk,
  input   rst_n,  
 
  slrx_regs_intrf.xlr slrx_regs_intrf, // Host Registers Interface
 
  // muxed interfaces
  mem_intf_read.client_read   mem_intf_read,
  mem_intf_write.client_write mem_intf_write
);

  enum {IDLE, READ_BIAS_VAL, READ_WGT_VEC, READ_IN_VEC, CALC, WRITE, DONE} next_state, state; 
  
  localparam DIM_MAX_SIZE = 32 ; 
  localparam MAX_DOT_PROD_WIDTH = 16+$clog2(DIM_MAX_SIZE) ; 

  localparam ARR_IDX_W = $clog2(DIM_MAX_SIZE);
  
  logic lin_start;  
  logic lin_done;  
  logic clear_done_on_read;

  logic [DIM_MAX_SIZE-1:0] [7:0] wgt_vec  ;       
  logic [DIM_MAX_SIZE-1:0] [7:0] wgt_vec_ps  ;    
  logic [DIM_MAX_SIZE-1:0] [7:0] in_vec  ;    
  logic [DIM_MAX_SIZE-1:0] [7:0] in_vec_ps  ; 

  logic [XMEM_ADDR_WIDTH-1:0] lin_wgt_arr_addr;
  logic [XMEM_ADDR_WIDTH-1:0] lin_arr_in_addr;  
  logic [XMEM_ADDR_WIDTH-1:0] lin_arr_out_addr; 
  logic [XMEM_ADDR_WIDTH-1:0] lin_bias_vec_addr;
  logic [XMEM_ADDR_WIDTH-1:0] bias_val_addr;
  
  logic [XMEM_ADDR_WIDTH-1:0] lin_rslt_out_addr, lin_rslt_out_addr_ps;  
  
  logic signed [31:0] bias_val, bias_val_ps ;    

  logic [ARR_IDX_W:0] lin_arr_in_dim ;
  logic [ARR_IDX_W:0] lin_arr_out_dim;   
  logic [ARR_IDX_W-1:0] lin_out_col_idx;
  
  logic [XMEM_ADDR_WIDTH-1:0] wgt_vec_addr_ps, wgt_vec_addr ;
  
  logic [7:0] lin_out_val ;    
  logic [7:0] lin_out_val_ps ; 
  
  logic lin_active ;
   
  //--------------------------------------------------------------------------------------------------------
    
  // Host Regs Interface 
  assign slrx_regs_intrf.xlr_done = lin_done ;
    
  slrx_cmd_t slrx_cmd ;
  
  assign slrx_cmd            = slrx_cmd_t'(slrx_regs_intrf.host_regs[XLR_START_RI][$clog2(NUM_SLRX_CMDS)-1:0])  ;
  assign lin_active          = (slrx_cmd==LIN_SETUP) || (slrx_cmd==LIN_CALC) ;
  assign lin_start           = slrx_regs_intrf.host_regs_valid_pulse[XLR_START_RI] && lin_active ;  
  
  // FIX: Removed 'lin_active' condition to prevent deadlock if host clears the cmd register during ack
  assign clear_done_on_read  = slrx_regs_intrf.xlr_done_ack ; 
  
  assign lin_wgt_arr_addr    = slrx_regs_intrf.host_regs[WGT_ADDR_RI];      
  assign lin_bias_vec_addr   = slrx_regs_intrf.host_regs[LIN_BIAS_ADDR_RI];  

  assign lin_arr_in_addr     = slrx_regs_intrf.host_regs[ARR_IN_ADDR_RI];    
  assign lin_arr_out_addr    = slrx_regs_intrf.host_regs[ARR_OUT_ADDR_RI];    
  assign lin_arr_in_dim      = slrx_regs_intrf.host_regs[ARR_IN_DIM_RI];      
  assign lin_arr_out_dim     = slrx_regs_intrf.host_regs[ARR_OUT_DIM_RI];     
  assign lin_out_col_idx     = slrx_regs_intrf.host_regs[OUT_COL_IDX_RI];     
   
  //======================================================================================================== 
 
  // State Machine Comb 
  always_comb begin
  
   next_state = state;
   
   bias_val_ps = bias_val ;
   in_vec_ps = in_vec ;

   mem_intf_read.mem_size_bytes  = 0;   
   mem_intf_read.mem_start_addr  = 0 ;    

   mem_intf_write.mem_size_bytes = 1;   
   mem_intf_write.mem_data       = lin_out_val;
   mem_intf_write.mem_start_addr = lin_rslt_out_addr;
   
   lin_rslt_out_addr_ps = lin_arr_out_addr + lin_out_col_idx  ; 
   
   mem_intf_read.mem_req = 0;
   mem_intf_write.mem_req = 0;   
   lin_done = 0;  

   wgt_vec_ps = wgt_vec  ;    
   wgt_vec_addr_ps = lin_wgt_arr_addr + (lin_out_col_idx * lin_arr_in_dim) ;  
   bias_val_addr = lin_bias_vec_addr + (4*lin_out_col_idx) ; 
      
   case (state)
   
      IDLE: if (lin_start) begin
       if      (slrx_cmd==LIN_SETUP) next_state = READ_IN_VEC; 
       else if (slrx_cmd==LIN_CALC)  next_state = READ_WGT_VEC;               
      end

      READ_IN_VEC: begin
        mem_intf_read.mem_req = 1;
        mem_intf_read.mem_start_addr = lin_arr_in_addr;
        mem_intf_read.mem_size_bytes = lin_arr_in_dim ;          
        if (mem_intf_read.mem_valid) begin
               for (int i=0;i<DIM_MAX_SIZE;i++) begin
                 in_vec_ps[i] = (i<lin_arr_in_dim) ? mem_intf_read.mem_data[i*8 +: 8] : 8'd0 ;
               end
               mem_intf_read.mem_req = 0;   
               next_state = DONE ; 
        end        
      end 

      READ_WGT_VEC: begin
        mem_intf_read.mem_req = 1; 
        mem_intf_read.mem_start_addr = wgt_vec_addr ;    
        mem_intf_read.mem_size_bytes = lin_arr_in_dim ;
        if (mem_intf_read.mem_valid) begin
          // FIX: Replaced 'integer i' to avoid syntax errors inside an unnamed block
          for (int i=0; i<DIM_MAX_SIZE; i++) begin
            wgt_vec_ps[i] = (i<lin_arr_in_dim) ? mem_intf_read.mem_data[i*8 +: 8] : 8'd0 ;
          end
          next_state = READ_BIAS_VAL; 
          mem_intf_read.mem_req = 0;
        end 
      end

      READ_BIAS_VAL: begin
        mem_intf_read.mem_req = 1;
        mem_intf_read.mem_start_addr = bias_val_addr;
        mem_intf_read.mem_size_bytes = 4 ;         
        if (mem_intf_read.mem_valid) begin
               mem_intf_read.mem_req = 0;
               bias_val_ps = mem_intf_read.mem_data[31:0] ;
               next_state = CALC ; 
        end 
      end 

      CALC : begin        
        next_state = WRITE ; 
      end

      WRITE: begin
        mem_intf_write.mem_req = 1;
        if (mem_intf_write.mem_ack) begin
          next_state = DONE;
          mem_intf_write.mem_req = 0;         
        end
      end 

      DONE: begin
        lin_done = 1;
        if (clear_done_on_read) next_state = IDLE; 
      end 
 
   endcase
  end 

  //-----------------------------------------------------------------------------------------------------
        
  assign lin_out_val_ps = calc_lin_element(wgt_vec, bias_val, in_vec) ;
  
  //------------------------------------------------------------------------

  // Sequential (Updated to SystemVerilog always_ff)
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin  
      state <= IDLE ;    
      wgt_vec_addr <= 0 ;
      wgt_vec <= 0;
      in_vec <= 0;
      lin_out_val <= 0;
      lin_rslt_out_addr <= 0;
      bias_val <= 0;
    end else begin     
      state <= next_state ;
      wgt_vec_addr <= wgt_vec_addr_ps ;
      wgt_vec <= wgt_vec_ps ;
      in_vec <= in_vec_ps; 
      lin_out_val <= lin_out_val_ps ; 
      lin_rslt_out_addr <= lin_rslt_out_addr_ps; 
      bias_val <= bias_val_ps ;          
    end    
  end
   
  //------------------------------------------------------------------------
 
  // Comb Function to calculate lin output element (Updated to SystemVerilog ANSI style)
  function automatic logic [7:0] calc_lin_element (
      input        [DIM_MAX_SIZE-1:0][7:0] wgt_vec,   
      input signed [31:0] bias_val,      
      input        [DIM_MAX_SIZE-1:0][7:0] in_vec 
  );
   
      logic signed [31:0] temp_sum;
      
      // Step 1: Initialize the accumulator with the Bias value
      temp_sum = bias_val;
      
      // Step 2: MAC loop 
      for (int i = 0; i < DIM_MAX_SIZE; i = i + 1) begin
          temp_sum = temp_sum + ($signed({1'b0, in_vec[i]}) * $signed(wgt_vec[i]));          
      end
      
      // Step 3 & 4: ReLU (first) and Descale (second)
      if (temp_sum < 0) begin
          return 8'd0;
      end else begin
          if ((temp_sum >> 8) > 255) begin
              return 8'd255;
          end else begin
              return (temp_sum >> 8);
          end
      end   
  endfunction
 
endmodule