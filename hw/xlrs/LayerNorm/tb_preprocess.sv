// Standalone testbench for preprocess_stage
// Tests 15 vectors from sole_test_in.txt
// ex_in / ex2_in taken from ex_ex2_stage golden values (tb_ex_ex2 verified)
// Golden mu_out / inv_std_out computed from sole_ref.c stage2_improved()
// inv_sqrt_lut loaded from /tmp/tb_pp_lut.hex

`timescale 1ns/1ps
import xbox_def_pkg::*;

module tb_preprocess;

  logic clk = 0;
  always #5 clk = ~clk;

  logic rst_n;
  logic start;
  logic [31:0] shared_addr;
  logic [31:0] num_channels;

  logic                                 pp_mem_req;
  logic [31:0]                          pp_mem_start_addr;
  logic [5:0]                           pp_mem_size_bytes;
  logic                                 pp_mem_valid;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] pp_mem_data;

  logic [63:0] ex_in;
  logic [63:0] ex2_in;
  logic [7:0]  min_alpha_in;

  logic [31:0] mu_out;
  logic [15:0] inv_std_out;
  logic        done;

  preprocess_stage dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .start            (start),
    .shared_addr      (shared_addr),
    .num_channels     (num_channels),
    .pp_mem_req       (pp_mem_req),
    .pp_mem_start_addr(pp_mem_start_addr),
    .pp_mem_size_bytes(pp_mem_size_bytes),
    .pp_mem_valid     (pp_mem_valid),
    .pp_mem_data      (pp_mem_data),
    .ex_in            (ex_in),
    .ex2_in           (ex2_in),
    .min_alpha_in     (min_alpha_in),
    .mu_out           (mu_out),
    .inv_std_out      (inv_std_out),
    .done             (done)
  );

  //------------------------------------------------------------------------
  // Fake memory: only inv_sqrt_lut needed (512 bytes at SHARED_BASE+1172)
  //   SHARED_BASE = 0x0000
  //   inv_sqrt_lut at 0x0000 + 1172 = 0x494, 512 bytes
  //------------------------------------------------------------------------
  localparam int SHARED_BASE = 32'h0000;

  logic [7:0] fake_mem [0:4095];

  initial begin
    // inv_sqrt_lut: 256 uint16_t entries, little-endian
    // byte 0 = LSB of entry 0, byte 1 = MSB of entry 0, ...
    $readmemh("/tmp/tb_pp_lut.hex", fake_mem, SHARED_BASE+1172, SHARED_BASE+1683);
  end

  //------------------------------------------------------------------------
  // Memory model: 2-cycle latency (identical to tb_ex_ex2 model)
  //------------------------------------------------------------------------
  typedef enum logic [1:0] { MEM_IDLE, MEM_WAIT, MEM_VALID } mem_state_t;
  mem_state_t mem_state;

  logic [31:0]                          mem_lat_addr;
  logic [5:0]                           mem_lat_size;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] mem_rdata;

  assign pp_mem_valid = (mem_state == MEM_VALID);
  assign pp_mem_data  = mem_rdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_state <= MEM_IDLE;
    end else begin
      case (mem_state)
        MEM_IDLE: begin
          if (pp_mem_req) begin
            mem_lat_addr <= pp_mem_start_addr;
            mem_lat_size <= pp_mem_size_bytes;
            mem_state    <= MEM_WAIT;
          end
        end
        MEM_WAIT: begin
          for (int i = 0; i < BYTES_PER_XMEM_LINE; i++)
            mem_rdata[i] <= (i < mem_lat_size) ? fake_mem[mem_lat_addr + i] : 8'd0;
          mem_state <= MEM_VALID;
        end
        MEM_VALID: begin
          mem_state <= MEM_IDLE;
        end
      endcase
    end
  end

  //------------------------------------------------------------------------
  // Task: run one test vector; print one result row
  //------------------------------------------------------------------------
  int pass_count;
  int fail_count;

  task automatic run_pp_test(
    input int    vec_id,
    input logic [63:0] t_ex,
    input logic [63:0] t_ex2,
    input logic [7:0]  t_min_alpha,
    input logic [31:0] g_mu,
    input logic [15:0] g_inv_std
  );
    automatic int timeout = 0;
    automatic logic mu_ok, is_ok;
    automatic logic signed [31:0] mu_delta;
    automatic logic signed [15:0] is_delta;

    ex_in        = t_ex;
    ex2_in       = t_ex2;
    min_alpha_in = t_min_alpha;

    // 2 idle cycles to ensure FSM is in IDLE
    repeat(2) @(posedge clk);

    // Pulse start
    @(posedge clk); start = 1'b1;
    @(posedge clk); start = 1'b0;

    // Wait for done
    timeout = 0;
    while (!done && timeout < 2000) begin
      @(posedge clk);
      timeout++;
    end

    if (timeout >= 2000) begin
      $display("  %3d | TIMEOUT", vec_id);
      fail_count++;
      return;
    end

    mu_ok    = (mu_out      === g_mu);
    is_ok    = (inv_std_out === g_inv_std);
    mu_delta = $signed(mu_out)      - $signed(g_mu);
    is_delta = $signed(inv_std_out) - $signed(g_inv_std);

    // Show golden vs computed with signed delta (0 = bit-exact)
    $display("  %3d | 0x%08h | 0x%08h | %4d | %s || 0x%04h | 0x%04h | %3d | %s || %s",
      vec_id,
      g_mu,        mu_out,      mu_delta,  mu_ok ? "OK" : "NG",
      g_inv_std,   inv_std_out, is_delta,  is_ok ? "OK" : "NG",
      (mu_ok && is_ok) ? "PASS" : "FAIL"
    );

    if (mu_ok && is_ok) pass_count++;
    else                fail_count++;
  endtask

  //------------------------------------------------------------------------
  // Stimulus: 15 vectors
  // ex/ex2 from tb_ex_ex2 golden; mu/inv_std from compute_pp_golden.py
  //------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;

    rst_n        = 1'b0;
    start        = 1'b0;
    shared_addr  = SHARED_BASE;
    num_channels = 32'd384;
    ex_in        = 64'd0;
    ex2_in       = 64'd0;
    min_alpha_in = 8'hfc;

    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);

    $display("");
    $display("=== PREPROCESS MULTI-VECTOR TESTBENCH ===");
    $display("  Vec | mu_golden   mu_RTL     delta cmp || is_golden is_RTL delta cmp || result");
    $display("  ----|--------------------------------------||----------------------------||-------");

    // vec_id, ex_in, ex2_in, min_alpha, golden_mu, golden_inv_std
    run_pp_test(  0, 64'h000000000000010c, 64'h000000000007b842, 8'hfc, 32'h00000000, 16'h0071);
    run_pp_test(  1, 64'hffffffffffffefd2, 64'h0000000000051aa0, 8'hfc, 32'hfffffff6, 16'h008b);
    run_pp_test(  2, 64'hfffffffffffff04a, 64'h000000000004ee5f, 8'hfc, 32'hfffffff6, 16'h008e);
    run_pp_test( 10, 64'hfffffffffffff215, 64'h000000000004be52, 8'hfc, 32'hfffffff7, 16'h0091);
    run_pp_test( 30, 64'hfffffffffffff596, 64'h0000000000051237, 8'hfc, 32'hfffffffa, 16'h008d);
    run_pp_test( 50, 64'hfffffffffffff677, 64'h000000000004d36d, 8'hfc, 32'hfffffffa, 16'h008f);
    run_pp_test( 75, 64'hfffffffffffff6e8, 64'h000000000005c1be, 8'hfc, 32'hfffffffa, 16'h0083);
    run_pp_test(100, 64'hfffffffffffffdef, 64'h0000000000045ef4, 8'hfc, 32'hffffffff, 16'h0097);
    run_pp_test(125, 64'hfffffffffffffbc8, 64'h00000000000628d2, 8'hfc, 32'hfffffffe, 16'h007f);
    run_pp_test(150, 64'hfffffffffffffbcc, 64'h000000000004e1f5, 8'hfc, 32'hfffffffe, 16'h008e);
    run_pp_test(175, 64'hfffffffffffff4d5, 64'h000000000004bd8b, 8'hfc, 32'hfffffff9, 16'h0091);
    run_pp_test(190, 64'hfffffffffffff628, 64'h0000000000049fdd, 8'hfc, 32'hfffffffa, 16'h0092);
    run_pp_test(193, 64'hfffffffffffff6ed, 64'h0000000000053c7b, 8'hfc, 32'hfffffffa, 16'h008a);
    run_pp_test(195, 64'hfffffffffffffaea, 64'h0000000000055db6, 8'hfc, 32'hfffffffd, 16'h0088);
    run_pp_test(196, 64'hfffffffffffffd46, 64'h00000000000585fd, 8'hfc, 32'hffffffff, 16'h0086);

    $display("  ----|--------------------------------------||----------------------------||-------");
    $display("  Passed: %0d / %0d", pass_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("  >>> ALL PASS <<<");
    else
      $display("  >>> %0d FAILURE(S) <<<", fail_count);
    $display("");

    $finish;
  end

  initial begin
    $dumpfile("/tmp/tb_preprocess.vcd");
    $dumpvars(0, tb_preprocess);
  end

endmodule
