// Standalone testbench for affine_stage
// Tests 15 vectors from sole_test_in.txt
// Golden output from compute_affine_golden_fixed.py (int16 xi_base, bit-exact C)
// Shared data (alpha/gamma/beta) and input vectors loaded from /tmp/ hex files

`timescale 1ns/1ps
import xbox_def_pkg::*;

module tb_affine;

  logic clk = 0;
  always #5 clk = ~clk;

  logic rst_n;
  logic start;

  logic [31:0] shared_addr;
  logic [31:0] input_addr;
  logic [31:0] output_addr;
  logic [31:0] num_channels;

  // DUT read port
  logic                                 af_rd_mem_req;
  logic [31:0]                          af_rd_mem_start_addr;
  logic [5:0]                           af_rd_mem_size_bytes;
  logic                                 af_rd_mem_valid;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] af_rd_mem_data;

  // DUT write port
  logic                                 af_wr_mem_req;
  logic [31:0]                          af_wr_mem_start_addr;
  logic [5:0]                           af_wr_mem_size_bytes;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] af_wr_mem_data;
  logic                                 af_wr_mem_ack;

  // Inputs from previous stages (from PreProcess + EX_EX2 golden values)
  logic [31:0] mu_in;
  logic [15:0] inv_std_in;
  logic [7:0]  min_alpha_in;
  logic [31:0] global_zp_in;
  logic [31:0] gamma_zp_in;
  logic [31:0] beta_zp_in;

  logic done;

  affine_stage #(.NUM_CH_MAX(384)) dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start               (start),
    .shared_addr         (shared_addr),
    .input_addr          (input_addr),
    .output_addr         (output_addr),
    .num_channels        (num_channels),
    .af_rd_mem_req       (af_rd_mem_req),
    .af_rd_mem_start_addr(af_rd_mem_start_addr),
    .af_rd_mem_size_bytes(af_rd_mem_size_bytes),
    .af_rd_mem_valid     (af_rd_mem_valid),
    .af_rd_mem_data      (af_rd_mem_data),
    .af_wr_mem_req       (af_wr_mem_req),
    .af_wr_mem_start_addr(af_wr_mem_start_addr),
    .af_wr_mem_size_bytes(af_wr_mem_size_bytes),
    .af_wr_mem_data      (af_wr_mem_data),
    .af_wr_mem_ack       (af_wr_mem_ack),
    .mu_in               (mu_in),
    .inv_std_in          (inv_std_in),
    .min_alpha_in        (min_alpha_in),
    .global_zp_in        (global_zp_in),
    .gamma_zp_in         (gamma_zp_in),
    .beta_zp_in          (beta_zp_in),
    .done                (done)
  );

  //------------------------------------------------------------------------
  // Memory layout
  //   SHARED_BASE = 0x0000
  //     alpha_factors at +20   (384 bytes, int8[384])
  //     gamma_q       at +404  (384 bytes, uint8[384])
  //     beta_q        at +788  (384 bytes, uint8[384])
  //   INPUT_BASE = 0x1000  (each slot: VEC_STRIDE=512 bytes)
  //   OUTPUT_BASE = 0x3000  (captured to output_buf, not in fake_mem)
  //------------------------------------------------------------------------
  localparam logic [31:0] SHARED_BASE = 32'h0000;
  localparam logic [31:0] INPUT_BASE  = 32'h1000;
  localparam logic [31:0] OUTPUT_BASE = 32'h3000;
  localparam int          VEC_STRIDE  = 512;

  logic [7:0] fake_mem    [0:16383];     // read-only memory backing
  logic [7:0] output_buf  [383:0];       // captured from DUT writes
  // golden_flat[slot*384 .. slot*384+383] holds the expected output for that slot
  logic [7:0] golden_flat [0:15*384-1];

  initial begin
    // Shared memory: alpha / gamma / beta arrays
    $readmemh("/tmp/tb_af_alpha.hex", fake_mem, SHARED_BASE+20,  SHARED_BASE+403);
    $readmemh("/tmp/tb_af_gamma.hex", fake_mem, SHARED_BASE+404, SHARED_BASE+787);
    $readmemh("/tmp/tb_af_beta.hex",  fake_mem, SHARED_BASE+788, SHARED_BASE+1171);

    // Input vectors: 15 slots, consecutive
    $readmemh("/tmp/tb_vec0.hex",   fake_mem, INPUT_BASE+ 0*VEC_STRIDE, INPUT_BASE+ 0*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec1.hex",   fake_mem, INPUT_BASE+ 1*VEC_STRIDE, INPUT_BASE+ 1*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec2.hex",   fake_mem, INPUT_BASE+ 2*VEC_STRIDE, INPUT_BASE+ 2*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec10.hex",  fake_mem, INPUT_BASE+ 3*VEC_STRIDE, INPUT_BASE+ 3*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec30.hex",  fake_mem, INPUT_BASE+ 4*VEC_STRIDE, INPUT_BASE+ 4*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec50.hex",  fake_mem, INPUT_BASE+ 5*VEC_STRIDE, INPUT_BASE+ 5*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec75.hex",  fake_mem, INPUT_BASE+ 6*VEC_STRIDE, INPUT_BASE+ 6*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec100.hex", fake_mem, INPUT_BASE+ 7*VEC_STRIDE, INPUT_BASE+ 7*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec125.hex", fake_mem, INPUT_BASE+ 8*VEC_STRIDE, INPUT_BASE+ 8*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec150.hex", fake_mem, INPUT_BASE+ 9*VEC_STRIDE, INPUT_BASE+ 9*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec175.hex", fake_mem, INPUT_BASE+10*VEC_STRIDE, INPUT_BASE+10*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec190.hex", fake_mem, INPUT_BASE+11*VEC_STRIDE, INPUT_BASE+11*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec193.hex", fake_mem, INPUT_BASE+12*VEC_STRIDE, INPUT_BASE+12*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec195.hex", fake_mem, INPUT_BASE+13*VEC_STRIDE, INPUT_BASE+13*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec196.hex", fake_mem, INPUT_BASE+14*VEC_STRIDE, INPUT_BASE+14*VEC_STRIDE+383);

    // Golden outputs: flat array, slot N at [N*384 .. N*384+383]
    $readmemh("/tmp/affine_golden/vec0.hex",   golden_flat,  0*384,  0*384+383);
    $readmemh("/tmp/affine_golden/vec1.hex",   golden_flat,  1*384,  1*384+383);
    $readmemh("/tmp/affine_golden/vec2.hex",   golden_flat,  2*384,  2*384+383);
    $readmemh("/tmp/affine_golden/vec10.hex",  golden_flat,  3*384,  3*384+383);
    $readmemh("/tmp/affine_golden/vec30.hex",  golden_flat,  4*384,  4*384+383);
    $readmemh("/tmp/affine_golden/vec50.hex",  golden_flat,  5*384,  5*384+383);
    $readmemh("/tmp/affine_golden/vec75.hex",  golden_flat,  6*384,  6*384+383);
    $readmemh("/tmp/affine_golden/vec100.hex", golden_flat,  7*384,  7*384+383);
    $readmemh("/tmp/affine_golden/vec125.hex", golden_flat,  8*384,  8*384+383);
    $readmemh("/tmp/affine_golden/vec150.hex", golden_flat,  9*384,  9*384+383);
    $readmemh("/tmp/affine_golden/vec175.hex", golden_flat, 10*384, 10*384+383);
    $readmemh("/tmp/affine_golden/vec190.hex", golden_flat, 11*384, 11*384+383);
    $readmemh("/tmp/affine_golden/vec193.hex", golden_flat, 12*384, 12*384+383);
    $readmemh("/tmp/affine_golden/vec195.hex", golden_flat, 13*384, 13*384+383);
    $readmemh("/tmp/affine_golden/vec196.hex", golden_flat, 14*384, 14*384+383);
  end

  //------------------------------------------------------------------------
  // Read memory model: 2-cycle latency
  //------------------------------------------------------------------------
  typedef enum logic [1:0] { MEM_IDLE, MEM_WAIT, MEM_VALID } rd_state_t;
  rd_state_t rd_mem_state;

  logic [31:0]                          rd_lat_addr;
  logic [5:0]                           rd_lat_size;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] rd_rdata;

  assign af_rd_mem_valid = (rd_mem_state == MEM_VALID);
  assign af_rd_mem_data  = rd_rdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_mem_state <= MEM_IDLE;
    end else begin
      case (rd_mem_state)
        MEM_IDLE: begin
          if (af_rd_mem_req) begin
            rd_lat_addr  <= af_rd_mem_start_addr;
            rd_lat_size  <= af_rd_mem_size_bytes;
            rd_mem_state <= MEM_WAIT;
          end
        end
        MEM_WAIT: begin
          for (int i = 0; i < BYTES_PER_XMEM_LINE; i++)
            rd_rdata[i] <= (i < rd_lat_size) ? fake_mem[rd_lat_addr + i] : 8'd0;
          rd_mem_state <= MEM_VALID;
        end
        MEM_VALID: begin
          rd_mem_state <= MEM_IDLE;
        end
      endcase
    end
  end

  //------------------------------------------------------------------------
  // Write memory model: 2-cycle latency, captures to output_buf
  //   WR_IDLE → WR_WAIT → WR_ACK (ack=1) → WR_IDLE
  //------------------------------------------------------------------------
  typedef enum logic [1:0] { WR_IDLE, WR_WAIT, WR_ACK } wr_state_t;
  wr_state_t wr_mem_state;

  logic [31:0]                          wr_lat_addr;
  logic [5:0]                           wr_lat_size;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] wr_lat_data;

  assign af_wr_mem_ack = (wr_mem_state == WR_ACK);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_mem_state <= WR_IDLE;
    end else begin
      case (wr_mem_state)
        WR_IDLE: begin
          if (af_wr_mem_req) begin
            wr_lat_addr  <= af_wr_mem_start_addr;
            wr_lat_size  <= af_wr_mem_size_bytes;
            wr_lat_data  <= af_wr_mem_data;
            wr_mem_state <= WR_WAIT;
          end
        end
        WR_WAIT: begin
          for (int i = 0; i < BYTES_PER_XMEM_LINE; i++)
            if (i < wr_lat_size)
              output_buf[wr_lat_addr - OUTPUT_BASE + i] <= wr_lat_data[i];
          wr_mem_state <= WR_ACK;
        end
        WR_ACK: begin
          wr_mem_state <= WR_IDLE;
        end
      endcase
    end
  end

  //------------------------------------------------------------------------
  // Task: run one test vector; print one result row
  //------------------------------------------------------------------------
  int pass_count;
  int fail_count;

  task automatic run_affine_test(
    input int slot,       // memory slot index (0..14)
    input int vec_id,     // actual vector number for display
    input int golden_idx, // index into golden[][] array
    input logic [31:0] t_mu,
    input logic [15:0] t_inv_std
  );
    automatic int cycles    = 0;
    automatic int timeout   = 0;
    automatic int mismatches = 0;
    automatic int first_ng  = -1;

    // Clear output_buf
    for (int k = 0; k < 384; k++) output_buf[k] = 8'd0;

    mu_in      = t_mu;
    inv_std_in = t_inv_std;

    input_addr = INPUT_BASE + slot * VEC_STRIDE;

    // 2 idle cycles
    repeat(2) @(posedge clk);

    // Pulse start
    @(posedge clk); start = 1'b1;
    @(posedge clk); start = 1'b0;

    // Wait for done
    cycles  = 0;
    timeout = 0;
    while (!done && timeout < 20000) begin
      @(posedge clk);
      timeout++;
      cycles++;
    end

    if (timeout >= 20000) begin
      $display("  %3d | TIMEOUT", vec_id);
      fail_count++;
      return;
    end

    // Count mismatches
    for (int k = 0; k < 384; k++) begin
      if (output_buf[k] !== golden_flat[golden_idx*384 + k]) begin
        if (first_ng < 0) first_ng = k;
        mismatches++;
      end
    end

    // Print: vec, first 4 golden, first 4 RTL, last 4 golden, last 4 RTL, result
    $display("  %3d | [%02h %02h %02h %02h] [%02h %02h %02h %02h] || [%02h %02h %02h %02h] [%02h %02h %02h %02h] | %s | %0d cyc",
      vec_id,
      golden_flat[golden_idx*384+0], golden_flat[golden_idx*384+1],
      golden_flat[golden_idx*384+2], golden_flat[golden_idx*384+3],
      output_buf[0],  output_buf[1],  output_buf[2],  output_buf[3],
      golden_flat[golden_idx*384+380], golden_flat[golden_idx*384+381],
      golden_flat[golden_idx*384+382], golden_flat[golden_idx*384+383],
      output_buf[380], output_buf[381], output_buf[382], output_buf[383],
      (mismatches == 0) ? "PASS" : "FAIL",
      cycles
    );

    if (mismatches > 0)
      $display("       ^ first mismatch at ch%0d, mismatches=%0d", first_ng, mismatches);

    if (mismatches == 0) pass_count++;
    else                 fail_count++;
  endtask

  //------------------------------------------------------------------------
  // Stimulus: 15 vectors
  // mu / inv_std from tb_preprocess golden (15/15 PASS previously)
  // min_alpha = 0xfc for all 15 vectors (from tb_ex_ex2 golden)
  // global_zp=128, gamma_zp=-2, beta_zp=146
  //------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;

    rst_n        = 1'b0;
    start        = 1'b0;
    shared_addr  = SHARED_BASE;
    input_addr   = INPUT_BASE;
    output_addr  = OUTPUT_BASE;
    num_channels = 32'd384;
    min_alpha_in = 8'hfc;
    global_zp_in = 32'd128;
    gamma_zp_in  = 32'hfffffffe;  // -2
    beta_zp_in   = 32'd146;
    mu_in        = 32'd0;
    inv_std_in   = 16'd0;

    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);

    $display("");
    $display("=== AFFINE MULTI-VECTOR TESTBENCH ===");
    $display("  Vec | golden y[0:3]  RTL y[0:3]   || golden y[380:383] RTL y[380:383] | result | cycles");
    $display("  ----|-------------------------------------------||--------------------------------|--------|-------");

    // slot, vec_id, golden_idx, mu,          inv_std
    run_affine_test( 0,   0,  0, 32'h00000000, 16'h0071);
    run_affine_test( 1,   1,  1, 32'hfffffff6, 16'h008b);
    run_affine_test( 2,   2,  2, 32'hfffffff6, 16'h008e);
    run_affine_test( 3,  10,  3, 32'hfffffff7, 16'h0091);
    run_affine_test( 4,  30,  4, 32'hfffffffa, 16'h008d);
    run_affine_test( 5,  50,  5, 32'hfffffffa, 16'h008f);
    run_affine_test( 6,  75,  6, 32'hfffffffa, 16'h0083);
    run_affine_test( 7, 100,  7, 32'hffffffff, 16'h0097);
    run_affine_test( 8, 125,  8, 32'hfffffffe, 16'h007f);
    run_affine_test( 9, 150,  9, 32'hfffffffe, 16'h008e);
    run_affine_test(10, 175, 10, 32'hfffffff9, 16'h0091);
    run_affine_test(11, 190, 11, 32'hfffffffa, 16'h0092);
    run_affine_test(12, 193, 12, 32'hfffffffa, 16'h008a);
    run_affine_test(13, 195, 13, 32'hfffffffd, 16'h0088);
    run_affine_test(14, 196, 14, 32'hffffffff, 16'h0086);

    $display("  ----|-------------------------------------------||--------------------------------|--------|-------");
    $display("  Passed: %0d / %0d", pass_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("  >>> ALL PASS <<<");
    else
      $display("  >>> %0d FAILURE(S) <<<", fail_count);
    $display("");

    $finish;
  end

  initial begin
    $dumpfile("/tmp/tb_affine.vcd");
    $dumpvars(0, tb_affine);
  end

endmodule
