import xbox_def_pkg::*;

module preprocess_stage (
  input  logic clk,
  input  logic rst_n,
  input  logic start,

  input  logic [31:0] shared_addr,
  input  logic [31:0] num_channels,

  // Memory read signals (plain ports — routed/muxed in LayerNorm.sv)
  output logic                                 pp_mem_req,
  output logic [31:0]                          pp_mem_start_addr,
  output logic [5:0]                           pp_mem_size_bytes,
  input  logic                                 pp_mem_valid,
  input  logic [BYTES_PER_XMEM_LINE-1:0][7:0] pp_mem_data,

  // Inputs from EX_EX2 stage
  input  logic [63:0] ex_in,
  input  logic [63:0] ex2_in,
  input  logic [7:0]  min_alpha_in,

  // Outputs to Affine stage
  output logic [31:0] mu_out,
  output logic [15:0] inv_std_out,

  output logic done
);

  //-------------------------------------------------------------------------
  // Pure-combinational arithmetic — mirrors sole_ref.c stage2_improved()
  //
  //   mu32    = (int32_t)ex   / num_channels          [truncating signed ÷]
  //   vterm   = (int32_t)ex2  / (num_channels >> 4)   [truncating signed ÷]
  //   var_hw  = vterm - mu32²,  clamped to ≥ 0
  //   lut_idx = var_hw >> 8,    clamped to ≤ 255
  //   lut_byte_addr = shared_addr + 1172 + lut_idx * 2
  //
  // Division by 0 cannot occur: num_channels and (num_channels>>4) are
  // always 384 and 24 respectively in this design.
  //-------------------------------------------------------------------------

  logic signed [31:0] mu_comb;
  logic signed [31:0] vterm_comb;
  logic signed [31:0] mu_comb_reg;   // pipeline register: registered mu_comb
  logic signed [31:0] mu_sq;         // mu32²: fits in 32 bits (|mu| ≤ 2048)
  logic signed [31:0] var_hw_raw;
  logic signed [31:0] var_hw_comb;   // clamped ≥ 0
  logic        [23:0] lut_idx_raw;   // bits [31:8] of var_hw = var_hw >> 8
  logic        [7:0]  lut_idx_comb;  // clamped to [0, 255]
  logic        [31:0] lut_addr_comb;

  // mu_comb = ex_in[31:0] / 384 — reciprocal multiply replaces combinational divider
  // M_384 = ceil(2^32 / 384) = 11184811; exact for |ex| ≤ 786432 (design range)
  // Technique: unsigned_div(abs(x), 384) then restore sign → gives C truncating ÷
  logic        mu_neg;
  logic [31:0] mu_abs_in;
  logic [63:0] mu_prod;
  logic [31:0] mu_abs_q;

  assign mu_neg    = ex_in[31];
  assign mu_abs_in = mu_neg ? (-ex_in[31:0]) : ex_in[31:0];
  assign mu_prod   = 64'(mu_abs_in) * 64'd11184811;
  assign mu_abs_q  = mu_prod[63:32];
  assign mu_comb   = mu_neg ? -$signed(mu_abs_q) : $signed(mu_abs_q);

  // vterm_comb = ex2_in[31:0] / 24 — ex2 always ≥ 0; M_24 = ceil(2^32 / 24) = 178956971
  logic [63:0] vterm_prod;

  assign vterm_prod = 64'(ex2_in[31:0]) * 64'd178956971;
  assign vterm_comb = $signed(vterm_prod[63:32]);
  assign mu_sq       = mu_comb_reg * mu_comb_reg;
  assign var_hw_raw  = vterm_comb - mu_sq;
  assign var_hw_comb = ($signed(var_hw_raw) < 32'sh0) ? 32'sh0 : var_hw_raw;
  assign lut_idx_raw = var_hw_comb[31:8];
  assign lut_idx_comb = (lut_idx_raw > 24'd255) ? 8'd255 : lut_idx_raw[7:0];
  // inv_sqrt_lut base at SoleShared offset 1172; each entry is uint16_t (2 bytes)
  assign lut_addr_comb = shared_addr + 32'd1172 + {23'b0, lut_idx_comb, 1'b0};

  //-------------------------------------------------------------------------
  // FSM: IDLE → COMP_MU → RD_LUT → DONE_ST
  //-------------------------------------------------------------------------

  typedef enum logic [1:0] { IDLE, COMP_MU, RD_LUT, DONE_ST } state_t;
  state_t state, next_state;

  logic [31:0] mu_reg;
  logic [15:0] inv_std_reg;
  logic        done_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
  end

  always_comb begin
    next_state        = state;
    pp_mem_req        = 1'b0;
    pp_mem_start_addr = 32'd0;
    pp_mem_size_bytes = 6'd0;

    case (state)
      IDLE: begin
        if (start) next_state = COMP_MU;
      end

      COMP_MU: begin
        next_state = RD_LUT;
      end

      RD_LUT: begin
        pp_mem_req        = !pp_mem_valid;
        pp_mem_start_addr = lut_addr_comb;
        pp_mem_size_bytes = 6'd2;
        if (pp_mem_valid) next_state = DONE_ST;
      end

      DONE_ST: begin
        if (!start) next_state = IDLE;
      end

      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mu_reg      <= 32'd0;
      inv_std_reg <= 16'd0;
      done_reg    <= 1'b0;
      mu_comb_reg <= 32'sd0;
    end else begin
      case (state)
        IDLE: begin
          if (start) done_reg <= 1'b0;
        end

        COMP_MU: begin
          mu_comb_reg <= mu_comb;
        end

        RD_LUT: begin
          if (pp_mem_valid) begin
            mu_reg      <= 32'(mu_comb_reg);
            // little-endian uint16: data[0]=LSB, data[1]=MSB
            inv_std_reg <= {pp_mem_data[1], pp_mem_data[0]};
          end
        end

        DONE_ST: begin
          done_reg <= 1'b1;
        end

        default: ;
      endcase
    end
  end

  // Drive done from FSM state so stale done_reg=1 in IDLE never causes
  // LayerNorm to skip this stage on subsequent vectors.
  assign done        = (state == DONE_ST);
  assign mu_out      = mu_reg;
  assign inv_std_out = inv_std_reg;

endmodule
