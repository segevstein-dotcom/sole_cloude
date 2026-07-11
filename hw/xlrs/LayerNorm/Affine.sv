import xbox_def_pkg::*;

module affine_stage #(
  parameter int NUM_CH_MAX = 384
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,

  input  logic [31:0] shared_addr,
  input  logic [31:0] input_addr,
  input  logic [31:0] output_addr,
  input  logic [31:0] num_channels,

  // Memory read signals (plain ports — routed/muxed in LayerNorm.sv)
  output logic                                 af_rd_mem_req,
  output logic [31:0]                          af_rd_mem_start_addr,
  output logic [5:0]                           af_rd_mem_size_bytes,
  input  logic                                 af_rd_mem_valid,
  input  logic [BYTES_PER_XMEM_LINE-1:0][7:0] af_rd_mem_data,

  // Memory write signals (plain ports — routed/muxed in LayerNorm.sv)
  output logic                                 af_wr_mem_req,
  output logic [31:0]                          af_wr_mem_start_addr,
  output logic [5:0]                           af_wr_mem_size_bytes,
  output logic [BYTES_PER_XMEM_LINE-1:0][7:0] af_wr_mem_data,
  input  logic                                 af_wr_mem_ack,

  // Inputs from previous stages
  input  logic [31:0] mu_in,
  input  logic [15:0] inv_std_in,
  input  logic [7:0]  min_alpha_in,
  input  logic [31:0] global_zp_in,
  input  logic [31:0] gamma_zp_in,
  input  logic [31:0] beta_zp_in,

  output logic done
);

  //-------------------------------------------------------------------------
  // FSM — 8 states, one pass per chunk:
  //   IDLE → (RD_ALPHA → RD_GAMMA → RD_BETA → RD_INPUT → PROCESS → WR_OUTPUT) × chunks → DONE_ST
  //-------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE, RD_ALPHA, RD_GAMMA, RD_BETA, RD_INPUT, PROCESS, WR_OUTPUT, DONE_ST
  } state_t;

  state_t state, next_state;

  // 32-byte line buffers — replace alpha/gamma/beta_buf[384] random-access arrays
  logic [7:0] alpha_line_buf [BYTES_PER_XMEM_LINE];
  logic [7:0] gamma_line_buf [BYTES_PER_XMEM_LINE];
  logic [7:0] beta_line_buf  [BYTES_PER_XMEM_LINE];
  logic [7:0] input_line_buf [BYTES_PER_XMEM_LINE];

  // Accumulated output for current chunk (filled in PROCESS, written in WR_OUTPUT)
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] out_reg;

  logic [3:0]  chunk_cnt;          // current chunk index (0..11 for 384 ch)
  logic [5:0]  lane_cnt;           // channel within current chunk (input pointer)
  logic [4:0]  num_chunks;         // ceil(num_channels / 32)
  logic [31:0] bytes_remaining;    // num_channels - chunk_cnt*32
  logic [5:0]  crnt_chunk_size;    // min(32, bytes_remaining)

  logic [31:0] alpha_chunk_addr;
  logic [31:0] gamma_chunk_addr;
  logic [31:0] beta_chunk_addr;
  logic [31:0] input_chunk_addr;
  logic [31:0] output_chunk_addr;

  //-------------------------------------------------------------------------
  // Per-channel pipelined computation — 4 pipeline registers (5 segments):
  //
  //   Seg 1 (7.1 ns):  lane_cnt → mux + 16-bit sub  → p1 {xi_base_s, rel_s, g_s, b_s}
  //   Seg 2 (6.2 ns):  p1 → shift + 32-bit sub       → p2 {xm_s}
  //   Seg 3 (7.1 ns):  p2 → Mult0 (xm × inv_std)     → p3 {xm_norm_s}
  //   Seg 4 (8.6 ns):  p3 → Mult1 (xm_norm × g)      → p4 {temp_s}
  //   Seg 5 (8.6 ns):  p4 → round + shift + clamp     → out_reg
  //
  // All ≤ 10 ns ⟹ required time 14.5 ns with 10 ns clock (100 MHz).
  // PROCESS duration: crnt_chunk_size + 4 cycles per chunk.
  //   For 384 ch (12 chunks × 32 lanes): 12×36 = 432 PROCESS cycles vs 384 before.
  //-------------------------------------------------------------------------

  // Stage 0 → Stage 1 combinational (from lane_cnt, line buffers)
  logic signed [15:0] s0_xi_base_s;
  logic signed [8:0]  s0_rdiff_s;
  logic        [4:0]  s0_rel_s;
  logic signed [31:0] s0_g_s;
  logic signed [31:0] s0_b_s;

  // Stage 1 registers
  logic signed [15:0] p1_xi_base_s;
  logic        [4:0]  p1_rel_s;
  logic signed [31:0] p1_g_s;
  logic signed [31:0] p1_b_s;
  logic        [5:0]  p1_lane;
  logic               p1_valid;

  // Stage 1 → Stage 2 combinational (from p1)
  logic signed [31:0] s1_xi_s;
  logic signed [31:0] s1_xm_s;

  // Stage 2 registers
  logic signed [31:0] p2_xm_s;
  logic signed [31:0] p2_g_s;
  logic signed [31:0] p2_b_s;
  logic        [5:0]  p2_lane;
  logic               p2_valid;

  // Stage 2 → Stage 3 combinational: Mult0 (from p2)
  logic signed [63:0] s2_xm_n64_s;
  logic signed [31:0] s2_xm_norm_s;

  // Stage 3 registers
  logic signed [31:0] p3_xm_norm_s;
  logic signed [31:0] p3_g_s;
  logic signed [31:0] p3_b_s;
  logic        [5:0]  p3_lane;
  logic               p3_valid;

  // Stage 3 → Stage 4 combinational: Mult1 (from p3)
  logic signed [63:0] s3_temp_s;

  // Stage 4 registers
  logic signed [63:0] p4_temp_s;
  logic signed [31:0] p4_b_s;
  logic        [5:0]  p4_lane;
  logic               p4_valid;

  // Stage 4 → output combinational (from p4)
  logic signed [63:0] s4_temp_r_s;
  logic signed [63:0] s4_shifted_s;
  logic signed [31:0] s4_y_pre_s;
  logic signed [7:0]  s4_y_comb_s;

  // Set once all inputs have entered stage 1; cleared outside PROCESS
  logic inputs_sent;

  //---------------------------------------------------------------------------
  // Combinational chunk addressing
  //---------------------------------------------------------------------------
  assign num_chunks        = 5'((num_channels + 32'd31) >> 5);
  assign bytes_remaining   = num_channels - (32'(chunk_cnt) << 5);
  assign crnt_chunk_size   = (bytes_remaining >= 32'd32) ? 6'd32 : bytes_remaining[5:0];
  assign alpha_chunk_addr  = shared_addr + 32'd20  + (32'(chunk_cnt) << 5);
  assign gamma_chunk_addr  = shared_addr + 32'd404 + (32'(chunk_cnt) << 5);
  assign beta_chunk_addr   = shared_addr + 32'd788 + (32'(chunk_cnt) << 5);
  assign input_chunk_addr  = input_addr  + (32'(chunk_cnt) << 5);
  assign output_chunk_addr = output_addr + (32'(chunk_cnt) << 5);

  //---------------------------------------------------------------------------
  // Stage 0 → Stage 1: mux + subtract (Seg 1, 7.1 ns)
  // Bit-width note: xi_base_s must be 16-bit signed to match C (int16_t)val−(int16_t)zp
  //---------------------------------------------------------------------------
  always_comb begin
    s0_xi_base_s = $signed({8'h0, input_line_buf[lane_cnt]}) - $signed(global_zp_in[15:0]);
    s0_rdiff_s   = 9'($signed(alpha_line_buf[lane_cnt])) - 9'($signed(min_alpha_in));
    s0_rel_s     = (|s0_rdiff_s[8:5]) ? 5'd31 : s0_rdiff_s[4:0];
    s0_g_s       = $signed({24'h0, gamma_line_buf[lane_cnt]}) - $signed(gamma_zp_in);
    s0_b_s       = $signed({24'h0, beta_line_buf[lane_cnt]}) - $signed(beta_zp_in);
  end

  //---------------------------------------------------------------------------
  // Stage 1 → Stage 2: shift + subtract (Seg 2, 6.2 ns)
  // 32-bit arithmetic left shift matches C: (int32_t)xi_base <<< rel_s
  //---------------------------------------------------------------------------
  always_comb begin
    s1_xi_s = $signed({{16{p1_xi_base_s[15]}}, p1_xi_base_s}) <<< p1_rel_s;
    s1_xm_s = s1_xi_s - $signed(mu_in);
  end

  //---------------------------------------------------------------------------
  // Stage 2 → Stage 3: Mult0 — xm × inv_std (Seg 3, 7.1 ns)
  // inv_std_in is uint16 (always positive) → zero-extend to 64 bits
  //---------------------------------------------------------------------------
  always_comb begin
    s2_xm_n64_s  = $signed({{32{p2_xm_s[31]}}, p2_xm_s}) * $signed({48'b0, inv_std_in});
    s2_xm_norm_s = s2_xm_n64_s[31:0];
  end

  //---------------------------------------------------------------------------
  // Stage 3 → Stage 4: Mult1 — xm_norm × g (Seg 4, 8.6 ns)
  //---------------------------------------------------------------------------
  always_comb begin
    s3_temp_s = $signed({{32{p3_xm_norm_s[31]}}, p3_xm_norm_s}) *
                $signed({{32{p3_g_s[31]}}, p3_g_s});
  end

  //---------------------------------------------------------------------------
  // Stage 4 → output: round + arithmetic shift + add beta + clamp (Seg 5, 8.6 ns)
  //---------------------------------------------------------------------------
  always_comb begin
    s4_temp_r_s  = p4_temp_s + 64'sh2000;
    s4_shifted_s = $signed(s4_temp_r_s) >>> 14;
    s4_y_pre_s   = $signed(s4_shifted_s[31:0]) + p4_b_s;
    if      ($signed(s4_y_pre_s) > 32'sh7f)  s4_y_comb_s = 8'sh7f;
    else if ($signed(s4_y_pre_s) < -32'sh80) s4_y_comb_s = 8'sh80;
    else                                       s4_y_comb_s = s4_y_pre_s[7:0];
  end

  //---------------------------------------------------------------------------
  // FSM sequential
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= next_state;
  end

  //---------------------------------------------------------------------------
  // FSM combinational
  //---------------------------------------------------------------------------
  always_comb begin
    next_state           = state;
    af_rd_mem_req        = 1'b0;
    af_rd_mem_start_addr = 32'd0;
    af_rd_mem_size_bytes = 6'd0;
    af_wr_mem_req        = 1'b0;
    af_wr_mem_start_addr = 32'd0;
    af_wr_mem_size_bytes = 6'd0;
    af_wr_mem_data       = '0;

    case (state)
      IDLE: begin
        if (start) next_state = RD_ALPHA;
      end

      RD_ALPHA: begin
        af_rd_mem_req        = !af_rd_mem_valid;
        af_rd_mem_start_addr = alpha_chunk_addr;
        af_rd_mem_size_bytes = crnt_chunk_size;
        if (af_rd_mem_valid) next_state = RD_GAMMA;
      end

      RD_GAMMA: begin
        af_rd_mem_req        = !af_rd_mem_valid;
        af_rd_mem_start_addr = gamma_chunk_addr;
        af_rd_mem_size_bytes = crnt_chunk_size;
        if (af_rd_mem_valid) next_state = RD_BETA;
      end

      RD_BETA: begin
        af_rd_mem_req        = !af_rd_mem_valid;
        af_rd_mem_start_addr = beta_chunk_addr;
        af_rd_mem_size_bytes = crnt_chunk_size;
        if (af_rd_mem_valid) next_state = RD_INPUT;
      end

      RD_INPUT: begin
        af_rd_mem_req        = !af_rd_mem_valid;
        af_rd_mem_start_addr = input_chunk_addr;
        af_rd_mem_size_bytes = crnt_chunk_size;
        if (af_rd_mem_valid) next_state = PROCESS;
      end

      PROCESS: begin
        // Exit when the last pipeline result has emerged from stage 4
        if (p4_valid && (p4_lane == 6'(crnt_chunk_size) - 6'd1))
          next_state = WR_OUTPUT;
      end

      WR_OUTPUT: begin
        af_wr_mem_req        = 1'b1;
        af_wr_mem_start_addr = output_chunk_addr;
        af_wr_mem_size_bytes = crnt_chunk_size;
        af_wr_mem_data       = out_reg;
        if (af_wr_mem_ack)
          next_state = (chunk_cnt == 4'(num_chunks - 1)) ? DONE_ST : RD_ALPHA;
      end

      DONE_ST: begin
        if (!start) next_state = IDLE;
      end

      default: next_state = IDLE;
    endcase
  end

  //---------------------------------------------------------------------------
  // Pipeline registers sequential
  // One channel enters stage 1 per cycle while inputs_sent=0.
  // After the last input, the pipeline drains for 4 more cycles.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      inputs_sent  <= 1'b0;
      p1_valid     <= 1'b0;
      p1_xi_base_s <= '0; p1_rel_s <= '0; p1_g_s <= '0; p1_b_s <= '0; p1_lane <= '0;
      p2_valid     <= 1'b0;
      p2_xm_s      <= '0; p2_g_s   <= '0; p2_b_s <= '0; p2_lane <= '0;
      p3_valid     <= 1'b0;
      p3_xm_norm_s <= '0; p3_g_s   <= '0; p3_b_s <= '0; p3_lane <= '0;
      p4_valid     <= 1'b0;
      p4_temp_s    <= '0; p4_b_s   <= '0; p4_lane <= '0;
    end else begin
      // inputs_sent: cleared whenever not in PROCESS; set when last input enters p1
      if (state != PROCESS)
        inputs_sent <= 1'b0;
      else if (!inputs_sent && (lane_cnt == 6'(crnt_chunk_size) - 6'd1))
        inputs_sent <= 1'b1;

      // Stage 0 → Stage 1: latch s0 signals and current lane index
      p1_valid     <= (state == PROCESS) && !inputs_sent;
      p1_xi_base_s <= s0_xi_base_s;
      p1_rel_s     <= s0_rel_s;
      p1_g_s       <= s0_g_s;
      p1_b_s       <= s0_b_s;
      p1_lane      <= lane_cnt;

      // Stage 1 → Stage 2
      p2_valid  <= p1_valid;
      p2_xm_s   <= s1_xm_s;
      p2_g_s    <= p1_g_s;
      p2_b_s    <= p1_b_s;
      p2_lane   <= p1_lane;

      // Stage 2 → Stage 3
      p3_valid     <= p2_valid;
      p3_xm_norm_s <= s2_xm_norm_s;
      p3_g_s       <= p2_g_s;
      p3_b_s       <= p2_b_s;
      p3_lane      <= p2_lane;

      // Stage 3 → Stage 4
      p4_valid  <= p3_valid;
      p4_temp_s <= s3_temp_s;
      p4_b_s    <= p3_b_s;
      p4_lane   <= p3_lane;
    end
  end

  //---------------------------------------------------------------------------
  // Data sequential (line buffers, counters, out_reg)
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      chunk_cnt <= 4'd0;
      lane_cnt  <= 6'd0;
      out_reg   <= '0;
      for (int k = 0; k < BYTES_PER_XMEM_LINE; k++) begin
        alpha_line_buf[k] <= 8'd0;
        gamma_line_buf[k] <= 8'd0;
        beta_line_buf[k]  <= 8'd0;
        input_line_buf[k] <= 8'd0;
      end
    end else begin
      case (state)
        IDLE: begin
          if (start) begin
            chunk_cnt <= 4'd0;
            lane_cnt  <= 6'd0;
          end
        end

        RD_ALPHA: begin
          if (af_rd_mem_valid) begin
            for (int k = 0; k < BYTES_PER_XMEM_LINE; k++)
              alpha_line_buf[k] <= af_rd_mem_data[k];
          end
        end

        RD_GAMMA: begin
          if (af_rd_mem_valid) begin
            for (int k = 0; k < BYTES_PER_XMEM_LINE; k++)
              gamma_line_buf[k] <= af_rd_mem_data[k];
          end
        end

        RD_BETA: begin
          if (af_rd_mem_valid) begin
            for (int k = 0; k < BYTES_PER_XMEM_LINE; k++)
              beta_line_buf[k] <= af_rd_mem_data[k];
          end
        end

        RD_INPUT: begin
          if (af_rd_mem_valid) begin
            for (int k = 0; k < BYTES_PER_XMEM_LINE; k++)
              input_line_buf[k] <= af_rd_mem_data[k];
            lane_cnt <= 6'd0;
          end
        end

        PROCESS: begin
          // Write pipeline output to chunk buffer when stage 4 is valid
          if (p4_valid)
            out_reg[p4_lane] <= 8'(s4_y_comb_s);
          // Advance input pointer during fill phase only
          if (!inputs_sent)
            lane_cnt <= lane_cnt + 6'd1;
        end

        WR_OUTPUT: begin
          // chunk_cnt increments here so output_chunk_addr is correct during write
          if (af_wr_mem_ack)
            chunk_cnt <= chunk_cnt + 4'd1;
        end

        default: ;
      endcase
    end
  end

  // Drive done from FSM state so stale value in IDLE never causes
  // LayerNorm to skip this stage on subsequent vectors.
  assign done = (state == DONE_ST);

endmodule
