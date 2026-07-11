import xbox_def_pkg::*;

module ex_ex2_stage #(
  parameter int NUM_CH_MAX = 384
)(
  input  logic clk,
  input  logic rst_n,
  input  logic start,

  input  logic [31:0] shared_addr,
  input  logic [31:0] input_addr,
  input  logic [31:0] num_channels,

  output logic                              ex_mem_req,
  output logic [31:0]                       ex_mem_start_addr,
  output logic [5:0]                        ex_mem_size_bytes,
  input  logic                              ex_mem_valid,
  input  logic [BYTES_PER_XMEM_LINE-1:0][7:0] ex_mem_data,

  input  logic [31:0] global_zp,

  output logic [63:0] ex_out,
  output logic [63:0] ex2_out,
  output logic [7:0]  min_alpha_out,

  output logic done
);

  // SQUARE_LUT: squares of 0..15
  function automatic [7:0] sq_lut(input [3:0] idx);
    case (idx)
      4'd0:  return 8'd0;    4'd1:  return 8'd1;
      4'd2:  return 8'd4;    4'd3:  return 8'd9;
      4'd4:  return 8'd16;   4'd5:  return 8'd25;
      4'd6:  return 8'd36;   4'd7:  return 8'd49;
      4'd8:  return 8'd64;   4'd9:  return 8'd81;
      4'd10: return 8'd100;  4'd11: return 8'd121;
      4'd12: return 8'd144;  4'd13: return 8'd169;
      4'd14: return 8'd196;  default: return 8'd225;
    endcase
  endfunction

  typedef enum logic [2:0] {
    IDLE, RD_MIN, RD_ALPHA, RD_INPUT, PROCESS, DONE_ST
  } state_t;

  state_t state, next_state;

  // 32-byte line buffers — replaces alpha_buf[384] random-access array
  logic [7:0] alpha_line_buf [BYTES_PER_XMEM_LINE];
  logic [7:0] input_line_buf [BYTES_PER_XMEM_LINE];

  logic [3:0]  chunk_cnt;         // current chunk index (0..11 for 384 ch)
  logic [5:0]  lane_cnt;          // channel within current chunk
  logic [4:0]  num_chunks;        // ceil(num_channels / 32)
  logic [31:0] bytes_remaining;   // num_channels - chunk_cnt*32
  logic [5:0]  crnt_chunk_size;   // min(32, bytes_remaining)
  logic [31:0] alpha_chunk_addr;  // shared_addr+20 + chunk_cnt*32
  logic [31:0] input_chunk_addr;  // input_addr + chunk_cnt*32

  logic [7:0]         min_alpha_reg;
  logic signed [63:0] ex_reg;
  logic        [63:0] ex2_reg;

  // Min alpha across current memory chunk (RD_MIN)
  logic [7:0] chunk_min_val;

  // Single-channel combinational signals (PROCESS state)
  logic signed [15:0] xi_s;
  logic        [7:0]  abs_x_s;
  logic        [8:0]  c_pre_s;
  logic        [3:0]  c_s;
  logic               s_s;
  logic        [11:0] xc2_s;
  logic signed [8:0]  rdiff_s;
  logic        [4:0]  rel_s;
  logic signed [31:0] xi32_s;
  logic signed [31:0] xi_sh_s;
  logic signed [63:0] xi64_s;
  logic        [63:0] xc2_sh_s;

  //---------------------------------------------------------------------------
  // Combinational chunk addressing
  //---------------------------------------------------------------------------
  assign num_chunks       = 5'((num_channels + 32'd31) >> 5);
  assign bytes_remaining  = num_channels - (32'(chunk_cnt) << 5);
  assign crnt_chunk_size  = (bytes_remaining >= 32'd32) ? 6'd32 : bytes_remaining[5:0];
  assign alpha_chunk_addr = shared_addr + 32'd20 + (32'(chunk_cnt) << 5);
  assign input_chunk_addr = input_addr  + (32'(chunk_cnt) << 5);

  //---------------------------------------------------------------------------
  // Combinational: min of current alpha chunk — balanced 5-level binary tree
  // Replaces 32-deep serial chain (~86 ns). num_channels=384=12×32 guarantees
  // crnt_chunk_size=32 for every chunk; j<crnt_chunk_size guard removed.
  //---------------------------------------------------------------------------
  logic [7:0] cmin_lv0 [0:15];
  logic [7:0] cmin_lv1 [0:7];
  logic [7:0] cmin_lv2 [0:3];
  logic [7:0] cmin_lv3 [0:1];

  always_comb begin
    for (int k = 0; k < 16; k++)
      cmin_lv0[k] = ($signed(ex_mem_data[2*k]) < $signed(ex_mem_data[2*k+1])) ?
                    ex_mem_data[2*k] : ex_mem_data[2*k+1];
    for (int k = 0; k < 8; k++)
      cmin_lv1[k] = ($signed(cmin_lv0[2*k]) < $signed(cmin_lv0[2*k+1])) ?
                    cmin_lv0[2*k] : cmin_lv0[2*k+1];
    for (int k = 0; k < 4; k++)
      cmin_lv2[k] = ($signed(cmin_lv1[2*k]) < $signed(cmin_lv1[2*k+1])) ?
                    cmin_lv1[2*k] : cmin_lv1[2*k+1];
    for (int k = 0; k < 2; k++)
      cmin_lv3[k] = ($signed(cmin_lv2[2*k]) < $signed(cmin_lv2[2*k+1])) ?
                    cmin_lv2[2*k] : cmin_lv2[2*k+1];
    chunk_min_val = ($signed(cmin_lv3[0]) < $signed(cmin_lv3[1])) ?
                    cmin_lv3[0] : cmin_lv3[1];
  end

  //---------------------------------------------------------------------------
  // Combinational: single-channel computation (PROCESS state)
  // Matches C: ex += (int64_t)((int32_t)xi << rel_shift)
  //            ex2 += (int64_t)(xc2 << (2*rel_shift))
  //---------------------------------------------------------------------------
  always_comb begin
    xi_s    = $signed({8'h00, input_line_buf[lane_cnt]}) - $signed(global_zp[15:0]);
    abs_x_s = xi_s[15] ? 8'(-xi_s[7:0]) : xi_s[7:0];

    if (abs_x_s < 8'd64) begin
      c_pre_s = (9'(abs_x_s) + 9'd2) >> 2;
      s_s     = 1'b0;
    end else begin
      c_pre_s = (9'(abs_x_s) + 9'd8) >> 4;
      s_s     = 1'b1;
    end
    c_s = (c_pre_s > 9'd15) ? 4'd15 : c_pre_s[3:0];

    xc2_s = s_s ? {sq_lut(c_s), 4'd0} : {4'd0, sq_lut(c_s)};

    rdiff_s = 9'($signed(alpha_line_buf[lane_cnt])) - 9'($signed(min_alpha_reg));
    rel_s   = (|rdiff_s[8:5]) ? 5'd31 : rdiff_s[4:0];

    // Critical: 32-bit intermediate shift then sign-extend to 64
    // matches C: (int64_t)((int32_t)xi << rel_shift)
    xi32_s  = {{16{xi_s[15]}}, xi_s};
    xi_sh_s = xi32_s <<< rel_s;
    xi64_s  = {{32{xi_sh_s[31]}}, xi_sh_s};

    xc2_sh_s = 64'(xc2_s) << (2 * rel_s);
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
    next_state        = state;
    ex_mem_req        = 1'b0;
    ex_mem_start_addr = 32'd0;
    ex_mem_size_bytes = 6'd0;

    case (state)
      IDLE: begin
        if (start) next_state = RD_MIN;
      end

      // Phase 1: read all alpha chunks to find global min_alpha
      RD_MIN: begin
        ex_mem_req        = !ex_mem_valid;
        ex_mem_start_addr = alpha_chunk_addr;
        ex_mem_size_bytes = crnt_chunk_size;
        if (ex_mem_valid && chunk_cnt == 4'(num_chunks - 1))
          next_state = RD_ALPHA;
      end

      // Phase 2: per-chunk: fetch alpha → fetch input → sequential process
      RD_ALPHA: begin
        ex_mem_req        = !ex_mem_valid;
        ex_mem_start_addr = alpha_chunk_addr;
        ex_mem_size_bytes = crnt_chunk_size;
        if (ex_mem_valid)
          next_state = RD_INPUT;
      end

      RD_INPUT: begin
        ex_mem_req        = !ex_mem_valid;
        ex_mem_start_addr = input_chunk_addr;
        ex_mem_size_bytes = crnt_chunk_size;
        if (ex_mem_valid)
          next_state = PROCESS;
      end

      PROCESS: begin
        // Exit when the last lane of this chunk is processed
        if (lane_cnt == 6'(crnt_chunk_size) - 6'd1)
          next_state = (chunk_cnt == 4'(num_chunks - 1)) ? DONE_ST : RD_ALPHA;
      end

      DONE_ST: begin
        if (!start) next_state = IDLE;
      end

      default: next_state = IDLE;
    endcase
  end

  //---------------------------------------------------------------------------
  // Data sequential
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      chunk_cnt     <= 4'd0;
      lane_cnt      <= 6'd0;
      min_alpha_reg <= 8'h7f;
      ex_reg        <= 64'sd0;
      ex2_reg       <= 64'd0;
      for (int k = 0; k < BYTES_PER_XMEM_LINE; k++) begin
        alpha_line_buf[k] <= 8'd0;
        input_line_buf[k] <= 8'd0;
      end
    end else begin
      case (state)
        IDLE: begin
          if (start) begin
            chunk_cnt     <= 4'd0;
            lane_cnt      <= 6'd0;
            min_alpha_reg <= 8'h7f;
            ex_reg        <= 64'sd0;
            ex2_reg       <= 64'd0;
          end
        end

        RD_MIN: begin
          if (ex_mem_valid) begin
            if ($signed(chunk_min_val) < $signed(min_alpha_reg))
              min_alpha_reg <= chunk_min_val;
            if (chunk_cnt == 4'(num_chunks - 1))
              chunk_cnt <= 4'd0;   // reset for Phase 2
            else
              chunk_cnt <= chunk_cnt + 4'd1;
          end
        end

        RD_ALPHA: begin
          if (ex_mem_valid) begin
            for (int k = 0; k < BYTES_PER_XMEM_LINE; k++)
              alpha_line_buf[k] <= ex_mem_data[k];
          end
        end

        RD_INPUT: begin
          if (ex_mem_valid) begin
            for (int k = 0; k < BYTES_PER_XMEM_LINE; k++)
              input_line_buf[k] <= ex_mem_data[k];
            lane_cnt <= 6'd0;
          end
        end

        PROCESS: begin
          ex_reg  <= ex_reg  + xi64_s;
          ex2_reg <= ex2_reg + xc2_sh_s;
          if (lane_cnt == 6'(crnt_chunk_size) - 6'd1) begin
            chunk_cnt <= chunk_cnt + 4'd1;
            lane_cnt  <= 6'd0;
          end else begin
            lane_cnt <= lane_cnt + 6'd1;
          end
        end

        default: ;
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Outputs
  //---------------------------------------------------------------------------
  assign done          = (state == DONE_ST);
  assign ex_out        = 64'(ex_reg);
  assign ex2_out       = ex2_reg;
  assign min_alpha_out = min_alpha_reg;

endmodule
