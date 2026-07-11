import xbox_def_pkg::*;

// TODO: evaluate pipelined operation (currently sequential: ZP→EX_EX2→PREPROCESS→AFFINE)

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

  /**************** Inter-stage result registers ****************/

  logic [31:0] global_zp;
  logic [31:0] gamma_zp;
  logic [31:0] beta_zp;
  logic [63:0] ex;
  logic [63:0] ex2;
  logic [7:0]  min_alpha;
  logic [31:0] mu;
  logic [15:0] inv_std;

  /**************** Per-stage memory bus signals ****************/

  // ZP read bus
  logic        zp_mem_req;
  logic [31:0] zp_mem_start_addr;
  logic [5:0]  zp_mem_size_bytes;

  // EX_EX2 read bus
  logic        ex_mem_req;
  logic [31:0] ex_mem_start_addr;
  logic [5:0]  ex_mem_size_bytes;

  // PreProcess read bus
  logic        pp_mem_req;
  logic [31:0] pp_mem_start_addr;
  logic [5:0]  pp_mem_size_bytes;

  // Affine read bus
  logic        af_rd_mem_req;
  logic [31:0] af_rd_mem_start_addr;
  logic [5:0]  af_rd_mem_size_bytes;

  // Affine write bus
  logic        af_wr_mem_req;
  logic [31:0] af_wr_mem_start_addr;
  logic [5:0]  af_wr_mem_size_bytes;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] af_wr_mem_data;

  /**************** mem_intf_read routing (FSM-state-driven) ****************/

  always_comb begin
    mem_intf_read.mem_req        = 1'b0;
    mem_intf_read.mem_start_addr = '0;
    mem_intf_read.mem_size_bytes = '0;

    case (state)
      ZP: begin
        mem_intf_read.mem_req        = zp_mem_req;
        mem_intf_read.mem_start_addr = zp_mem_start_addr;
        mem_intf_read.mem_size_bytes = zp_mem_size_bytes;
      end
      EX_EX2: begin
        mem_intf_read.mem_req        = ex_mem_req;
        mem_intf_read.mem_start_addr = ex_mem_start_addr;
        mem_intf_read.mem_size_bytes = ex_mem_size_bytes;
      end
      PREPROCESS: begin
        mem_intf_read.mem_req        = pp_mem_req;
        mem_intf_read.mem_start_addr = pp_mem_start_addr;
        mem_intf_read.mem_size_bytes = pp_mem_size_bytes;
      end
      AFFINE: begin
        mem_intf_read.mem_req        = af_rd_mem_req;
        mem_intf_read.mem_start_addr = af_rd_mem_start_addr;
        mem_intf_read.mem_size_bytes = af_rd_mem_size_bytes;
      end
      default: ; // IDLE / DONE — no memory access
    endcase
  end

  /**************** mem_intf_write routing (Affine only) ****************/

  always_comb begin
    mem_intf_write.mem_req        = 1'b0;
    mem_intf_write.mem_start_addr = '0;
    mem_intf_write.mem_size_bytes = '0;
    mem_intf_write.mem_data       = '0;

    if (state == AFFINE) begin
      mem_intf_write.mem_req        = af_wr_mem_req;
      mem_intf_write.mem_start_addr = af_wr_mem_start_addr;
      mem_intf_write.mem_size_bytes = af_wr_mem_size_bytes;
      mem_intf_write.mem_data       = af_wr_mem_data;
    end
  end

  /**************** Host DONE register ****************/

  assign start_layernorm =
      host_regs_valid_pulse[SOLE_START_REG_IDX] &&
      host_regs[SOLE_START_REG_IDX][0];

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

  /**************** Vector counter for RTL log ****************/

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

    // Debug: print Affine inputs at PREPROCESS→AFFINE transition (first 5 vectors)
    if (state == PREPROCESS && preprocess_done && vector_cnt <= 32'd5)
      $display("DBG VEC%0d: shared=0x%08x in=0x%08x out=0x%08x mu=%0d inv_std=%0d min_alpha=%0d global_zp=%0d gamma_zp=%0d beta_zp=%0d",
               vector_cnt - 1, shared_addr, input_addr, output_addr,
               $signed(mu), inv_std, $signed(min_alpha),
               $signed(global_zp), $signed(gamma_zp), $signed(beta_zp));
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

  /**************** Stage instantiations ****************/

  zp_stage i_zp_stage (
    .clk              (clk),
    .rst_n            (rst_n),
    .start            (zp_start),
    .shared_addr      (shared_addr),
    .zp_mem_req       (zp_mem_req),
    .zp_mem_start_addr(zp_mem_start_addr),
    .zp_mem_size_bytes(zp_mem_size_bytes),
    .zp_mem_valid     (mem_intf_read.mem_valid),
    .zp_mem_data      (mem_intf_read.mem_data),
    .global_zp_out    (global_zp),
    .gamma_zp_out     (gamma_zp),
    .beta_zp_out      (beta_zp),
    .done             (zp_done)
  );

  ex_ex2_stage i_ex_ex2_stage (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start               (ex_ex2_start),
    .shared_addr         (shared_addr),
    .input_addr          (input_addr),
    .num_channels        (num_channels),
    .ex_mem_req          (ex_mem_req),
    .ex_mem_start_addr   (ex_mem_start_addr),
    .ex_mem_size_bytes   (ex_mem_size_bytes),
    .ex_mem_valid        (mem_intf_read.mem_valid),
    .ex_mem_data         (mem_intf_read.mem_data),
    .global_zp           (global_zp),
    .ex_out              (ex),
    .ex2_out             (ex2),
    .min_alpha_out       (min_alpha),
    .done                (ex_ex2_done)
  );

  preprocess_stage i_preprocess_stage (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start               (preprocess_start),
    .shared_addr         (shared_addr),
    .num_channels        (num_channels),
    .pp_mem_req          (pp_mem_req),
    .pp_mem_start_addr   (pp_mem_start_addr),
    .pp_mem_size_bytes   (pp_mem_size_bytes),
    .pp_mem_valid        (mem_intf_read.mem_valid),
    .pp_mem_data         (mem_intf_read.mem_data),
    .ex_in               (ex),
    .ex2_in              (ex2),
    .min_alpha_in        (min_alpha),
    .mu_out              (mu),
    .inv_std_out         (inv_std),
    .done                (preprocess_done)
  );

  affine_stage i_affine_stage (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start               (affine_start),
    .shared_addr         (shared_addr),
    .input_addr          (input_addr),
    .output_addr         (output_addr),
    .num_channels        (num_channels),
    .af_rd_mem_req       (af_rd_mem_req),
    .af_rd_mem_start_addr(af_rd_mem_start_addr),
    .af_rd_mem_size_bytes(af_rd_mem_size_bytes),
    .af_rd_mem_valid     (mem_intf_read.mem_valid),
    .af_rd_mem_data      (mem_intf_read.mem_data),
    .af_wr_mem_req       (af_wr_mem_req),
    .af_wr_mem_start_addr(af_wr_mem_start_addr),
    .af_wr_mem_size_bytes(af_wr_mem_size_bytes),
    .af_wr_mem_data      (af_wr_mem_data),
    .af_wr_mem_ack       (mem_intf_write.mem_ack),
    .mu_in               (mu),
    .inv_std_in          (inv_std),
    .min_alpha_in        (min_alpha),
    .global_zp_in        (global_zp),
    .gamma_zp_in         (gamma_zp),
    .beta_zp_in          (beta_zp),
    .done                (affine_done)
  );

endmodule
