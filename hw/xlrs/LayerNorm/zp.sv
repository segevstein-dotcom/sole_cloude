import xbox_def_pkg::*;

module zp_stage (
  input  logic clk,
  input  logic rst_n,
  input  logic start,

  input  logic [31:0] shared_addr,
  
  // Memory read interface from LayerNorm top module
  mem_intf_read.client_read   mem_intf_read,

  // Output to be used by the EX_EX2 stage
  output logic [31:0] global_zp_out,
  
  output logic done
);

  // Define internal states for the ZP fetch process
  typedef enum logic [1:0] {
    IDLE,
    REQ_READ,
    WAIT_DATA,
    DONE
  } zp_state_t;

  zp_state_t state, next_state;
  logic [31:0] global_zp_reg;
  logic        done_reg;

  // ---------------------------------------------------------
  // State Machine Sequential Logic
  // ---------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  // ---------------------------------------------------------
  // Data Capture & Done Signal Sequential Logic
  // ---------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      global_zp_reg <= 32'd0;
      done_reg      <= 1'b0;
    end else begin
      if (state == IDLE && start) begin
        // Clear done flag when a new start pulse arrives
        done_reg <= 1'b0;
      end else if (state == WAIT_DATA && mem_intf_read.mem_valid) begin
        // Assuming global_zp is a 32-bit integer (4 bytes)
        // Adjust the byte packing based on your specific mem_data endianness if needed
        global_zp_reg <= {mem_intf_read.mem_data[3], 
                          mem_intf_read.mem_data[2], 
                          mem_intf_read.mem_data[1], 
                          mem_intf_read.mem_data[0]};
      end else if (state == DONE) begin
        done_reg <= 1'b1;
      end
    end
  end

  assign global_zp_out = global_zp_reg;
  assign done          = done_reg;

  // ---------------------------------------------------------
  // State Machine Combinational Logic
  // ---------------------------------------------------------
  always_comb begin
    // Default assignments
    next_state = state;
    
    // Default memory interface assignments
    mem_intf_read.mem_req        = 1'b0;
    mem_intf_read.mem_start_addr = 32'd0;
    mem_intf_read.mem_size_bytes = 32'd0;

    case (state)
      IDLE: begin
        if (start) begin
          next_state = REQ_READ;
        end
      end

      REQ_READ: begin
        // global_zp is the 3rd element in the SoleShared struct (after two int32_t fields)
        // Address offset: 2 * 4 bytes = 8 bytes
        mem_intf_read.mem_start_addr = shared_addr + 32'd8; 
        mem_intf_read.mem_size_bytes = 32'd4; // Read 4 bytes (32-bit int)
        mem_intf_read.mem_req        = 1'b1;
        
        next_state = WAIT_DATA;
      end

      WAIT_DATA: begin
        if (mem_intf_read.mem_valid) begin
          next_state = DONE;
        end
      end

      DONE: begin
        // Wait here until the top FSM removes the start signal 
        // (to prevent re-triggering while transitioning to EX_EX2)
        if (!start) begin
          next_state = IDLE;
        end
      end

      default: next_state = IDLE;
    endcase
  end

endmodule