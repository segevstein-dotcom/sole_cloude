import xbox_def_pkg::*;

module LayerNorm (
  input  logic clk,
  input  logic rst_n,

  input  logic [XBOX_NUM_REGS-1:0][31:0] host_regs,
  input  logic [XBOX_NUM_REGS-1:0]        host_regs_valid_pulse,
  output logic [XBOX_NUM_REGS-1:0][31:0] host_regs_data_out,
  output logic [XBOX_NUM_REGS-1:0]        host_regs_valid_out,
  input  logic [XBOX_NUM_REGS-1:0]        host_regs_read_pulse,

  mem_intf_read.client_read   mem_intf_read,
  mem_intf_write.client_write mem_intf_write
);

  typedef enum logic [2:0] {
    IDLE,
    ZP,
    EX_EX2,
    PREPROCESS,
    AFFINE,
    DONE
  } state_t;

  enum {
    SOLE_SHARED_ADDR_REG_IDX = 0,
    SOLE_INPUT_ADDR_REG_IDX  = 1,
    SOLE_OUTPUT_ADDR_REG_IDX = 2,
    SOLE_NUM_CH_REG_IDX      = 3,
    SOLE_START_REG_IDX       = 4,
    SOLE_DONE_REG_IDX        = 5
  } regs_idx;

  state_t state, next_state;

  logic [31:0] shared_addr;
  logic [31:0] input_addr;
  logic [31:0] output_addr;
  logic [31:0] num_channels;
  logic [31:0] vector_cnt;

  logic start_layernorm;
  logic layernorm_done;
  logic done_sticky;

  logic zp_start;
  logic ex_ex2_start;
  logic preprocess_start;
  logic affine_start;

  logic zp_done;
  logic ex_ex2_done;
  logic preprocess_done;
  logic affine_done;
  
  // ---> New addition: Internal wire to capture the global Zero Point from the first module <---
  logic [31:0] global_zp; 

  assign start_layernorm =
      host_regs_valid_pulse[SOLE_START_REG_IDX] &&
      host_regs[SOLE_START_REG_IDX][0];

  /**************** Memory interface placeholders ****************/

  // ---> Commented out: The ZP module now controls the read signals! <---
  // assign mem_intf_read.mem_req        = 1'b0;
  // assign mem_intf_read.mem_start_addr = '0;
  // assign mem_intf_read.mem_size_bytes = '0;

  assign mem_intf_write.mem_req        = 1'b0;
  assign mem_intf_write.mem_start_addr = '0;
  assign mem_intf_write.mem_size_bytes = '0;
  assign mem_intf_write.mem_data       = '0;

  /**************** Host DONE register ****************/

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_sticky <= 1'b0;
    end else begin
      if (start_layernorm)
        done_sticky <= 1'b0;
      else if (layernorm_done)
        done_sticky <= 1'b1;
    end
  end

  always_comb begin
    host_regs_data_out  = '0;
    host_regs_valid_out = '0;

    host_regs_data_out[SOLE_DONE_REG_IDX]  = {31'b0, done_sticky};
    host_regs_valid_out[SOLE_DONE_REG_IDX] = 1'b1;
  end

  /**************** Vector counter for clean RTL log ****************/

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vector_cnt <= 32'd0;
    end else if (start_layernorm) begin
      vector_cnt <= vector_cnt + 32'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (start_layernorm)
      $display("LayerNorm RTL: START vector %0d", vector_cnt);

    if (layernorm_done)
      $display("LayerNorm RTL: DONE vector %0d", vector_cnt - 32'd1);
  end

  /**************** Capture configuration registers on START ****************/

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shared_addr  <= 32'b0;
      input_addr   <= 32'b0;
      output_addr  <= 32'b0;
      num_channels <= 32'b0;
    end else if (start_layernorm) begin
      shared_addr  <= host_regs[SOLE_SHARED_ADDR_REG_IDX];
      input_addr   <= host_regs[SOLE_INPUT_ADDR_REG_IDX];
      output_addr  <= host_regs[SOLE_OUTPUT_ADDR_REG_IDX];
      num_channels <= host_regs[SOLE_NUM_CH_REG_IDX];
    end
  end

  /**************** FSM sequential ****************/

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      state <= IDLE;
    else
      state <= next_state;
  end

  /**************** FSM combinational ****************/

  always_comb begin
    next_state = state;

    layernorm_done   = 1'b0;

    zp_start         = 1'b0;
    ex_ex2_start     = 1'b0;
    preprocess_start = 1'b0;
    affine_start     = 1'b0;

    case (state)

      IDLE: begin
        if (start_layernorm)
          next_state = ZP;
      end

      ZP: begin
        zp_start = 1'b1;

        if (zp_done)
          next_state = EX_EX2;
      end

      EX_EX2: begin
        ex_ex2_start = 1'b1;

        if (ex_ex2_done)
          next_state = PREPROCESS;
      end

      PREPROCESS: begin
        preprocess_start = 1'b1;

        if (preprocess_done)
          next_state = AFFINE;
      end

      AFFINE: begin
        affine_start = 1'b1;

        if (affine_done)
          next_state = DONE;
      end

      DONE: begin
        layernorm_done = 1'b1;
        next_state     = IDLE;
      end

      default: begin
        next_state = IDLE;
      end

    endcase
  end

  /**************** Active computation stages ****************/

  // ---> Updated ZP instance with connection to memory and the global_zp wire <---
  zp_stage i_zp_stage (
    .clk           (clk),
    .rst_n         (rst_n),
    .start         (zp_start),
    .shared_addr   (shared_addr),
    .mem_intf_read (mem_intf_read), 
    .global_zp_out (global_zp),     
    .done          (zp_done)
  );

  ex_ex2_stage i_ex_ex2_stage (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (ex_ex2_start),
    .shared_addr  (shared_addr),
    .input_addr   (input_addr),
    .num_channels (num_channels),
    // In the future, we will pass the captured global_zp here
    .done         (ex_ex2_done)
  );

  preprocess_stage i_preprocess_stage (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (preprocess_start),
    .shared_addr  (shared_addr),
    .num_channels (num_channels),
    .done         (preprocess_done)
  );

  affine_stage i_affine_stage (
    .clk          (clk),
    .rst_n        (rst_n),
    .start        (affine_start),
    .shared_addr  (shared_addr),
    .input_addr   (input_addr),
    .output_addr  (output_addr),
    .num_channels (num_channels),
    .done         (affine_done)
  );

endmodule