import xbox_def_pkg::*;

module zp_stage (
  input  logic clk,
  input  logic rst_n,
  input  logic start,

  input  logic [31:0] shared_addr,

  // Memory read signals (plain ports — routed/muxed in LayerNorm.sv)
  output logic                              zp_mem_req,
  output logic [31:0]                       zp_mem_start_addr,
  output logic [5:0]                        zp_mem_size_bytes,
  input  logic                              zp_mem_valid,
  input  logic [BYTES_PER_XMEM_LINE-1:0][7:0] zp_mem_data,

  // Outputs to downstream stages
  output logic [31:0] global_zp_out,
  output logic [31:0] gamma_zp_out,
  output logic [31:0] beta_zp_out,

  output logic done
);

  typedef enum logic [1:0] {
    IDLE,
    REQ_READ,
    WAIT_DATA,
    DONE
  } zp_state_t;

  zp_state_t state, next_state;
  logic [31:0] global_zp_reg;
  logic [31:0] gamma_zp_reg;
  logic [31:0] beta_zp_reg;
  logic        done_reg;

  // State register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
  end

  // Data capture and done flag
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      global_zp_reg <= 32'd0;
      gamma_zp_reg  <= 32'd0;
      beta_zp_reg   <= 32'd0;
      done_reg      <= 1'b0;
    end else begin
      if (state == IDLE && start) begin
        done_reg <= 1'b0;
      end else if (state == WAIT_DATA && zp_mem_valid) begin
        global_zp_reg <= {zp_mem_data[3],  zp_mem_data[2],  zp_mem_data[1],  zp_mem_data[0]};
        gamma_zp_reg  <= {zp_mem_data[7],  zp_mem_data[6],  zp_mem_data[5],  zp_mem_data[4]};
        beta_zp_reg   <= {zp_mem_data[11], zp_mem_data[10], zp_mem_data[9],  zp_mem_data[8]};
      end else if (state == DONE) begin
        done_reg <= 1'b1;
      end
    end
  end

  assign global_zp_out = global_zp_reg;
  assign gamma_zp_out  = gamma_zp_reg;
  assign beta_zp_out   = beta_zp_reg;
  assign done = (state == DONE);

  // State machine combinational
  always_comb begin
    next_state        = state;
    zp_mem_req        = 1'b0;
    zp_mem_start_addr = 32'd0;
    zp_mem_size_bytes = 6'd0;

    case (state)
      IDLE: begin
        if (start)
          next_state = REQ_READ;
      end

      REQ_READ: begin
        // global_zp/gamma_zp/beta_zp at SoleShared offsets 8/12/16 — read 12 bytes
        zp_mem_start_addr = shared_addr + 32'd8;
        zp_mem_size_bytes = 6'd12;
        zp_mem_req        = 1'b1;
        next_state        = WAIT_DATA;
      end

      WAIT_DATA: begin
        if (zp_mem_valid)
          next_state = DONE;
      end

      DONE: begin
        if (!start)
          next_state = IDLE;
      end

      default: next_state = IDLE;
    endcase
  end

endmodule
