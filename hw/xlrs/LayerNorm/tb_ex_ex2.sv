// Standalone testbench for ex_ex2_stage
// Tests 15 vectors from sole_test_in.txt; golden values from sole_ref.c algorithm
// Vectors: 0,1,2,10,30,50,75,100,125,150,175,190,193,195,196

`timescale 1ns/1ps
import xbox_def_pkg::*;

module tb_ex_ex2;

  logic clk = 0;
  always #5 clk = ~clk;

  logic rst_n;
  logic        start;
  logic [31:0] shared_addr;
  logic [31:0] input_addr;
  logic [31:0] num_channels;
  logic [31:0] global_zp;

  logic                                 ex_mem_req;
  logic [31:0]                          ex_mem_start_addr;
  logic [5:0]                           ex_mem_size_bytes;
  logic                                 ex_mem_valid;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] ex_mem_data;

  logic [63:0] ex_out;
  logic [63:0] ex2_out;
  logic [7:0]  min_alpha_out;
  logic        done;

  ex_ex2_stage #(.NUM_CH_MAX(384)) dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .start            (start),
    .shared_addr      (shared_addr),
    .input_addr       (input_addr),
    .num_channels     (num_channels),
    .ex_mem_req       (ex_mem_req),
    .ex_mem_start_addr(ex_mem_start_addr),
    .ex_mem_size_bytes(ex_mem_size_bytes),
    .ex_mem_valid     (ex_mem_valid),
    .ex_mem_data      (ex_mem_data),
    .global_zp        (global_zp),
    .ex_out           (ex_out),
    .ex2_out          (ex2_out),
    .min_alpha_out    (min_alpha_out),
    .done             (done)
  );

  //------------------------------------------------------------------------
  // Fake memory: 16 KB
  //   SHARED_BASE = 0x0000  (alpha_factors at +20..+403)
  //   INPUT_BASE  = 0x0800  (vector slot N at +N*VEC_STRIDE, stride=512)
  //------------------------------------------------------------------------
  localparam int SHARED_BASE = 32'h0000;
  localparam int INPUT_BASE  = 32'h0800;
  localparam int VEC_STRIDE  = 512;

  logic [7:0] fake_mem [0:16383];

  initial begin
    $readmemh("/tmp/tb_alpha.hex",   fake_mem, SHARED_BASE+20,            SHARED_BASE+403);
    $readmemh("/tmp/tb_vec0.hex",    fake_mem, INPUT_BASE+ 0*VEC_STRIDE,  INPUT_BASE+ 0*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec1.hex",    fake_mem, INPUT_BASE+ 1*VEC_STRIDE,  INPUT_BASE+ 1*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec2.hex",    fake_mem, INPUT_BASE+ 2*VEC_STRIDE,  INPUT_BASE+ 2*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec10.hex",   fake_mem, INPUT_BASE+ 3*VEC_STRIDE,  INPUT_BASE+ 3*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec30.hex",   fake_mem, INPUT_BASE+ 4*VEC_STRIDE,  INPUT_BASE+ 4*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec50.hex",   fake_mem, INPUT_BASE+ 5*VEC_STRIDE,  INPUT_BASE+ 5*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec75.hex",   fake_mem, INPUT_BASE+ 6*VEC_STRIDE,  INPUT_BASE+ 6*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec100.hex",  fake_mem, INPUT_BASE+ 7*VEC_STRIDE,  INPUT_BASE+ 7*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec125.hex",  fake_mem, INPUT_BASE+ 8*VEC_STRIDE,  INPUT_BASE+ 8*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec150.hex",  fake_mem, INPUT_BASE+ 9*VEC_STRIDE,  INPUT_BASE+ 9*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec175.hex",  fake_mem, INPUT_BASE+10*VEC_STRIDE,  INPUT_BASE+10*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec190.hex",  fake_mem, INPUT_BASE+11*VEC_STRIDE,  INPUT_BASE+11*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec193.hex",  fake_mem, INPUT_BASE+12*VEC_STRIDE,  INPUT_BASE+12*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec195.hex",  fake_mem, INPUT_BASE+13*VEC_STRIDE,  INPUT_BASE+13*VEC_STRIDE+383);
    $readmemh("/tmp/tb_vec196.hex",  fake_mem, INPUT_BASE+14*VEC_STRIDE,  INPUT_BASE+14*VEC_STRIDE+383);
  end

  //------------------------------------------------------------------------
  // Memory model: 2-cycle latency
  //------------------------------------------------------------------------
  typedef enum logic [1:0] { MEM_IDLE, MEM_WAIT, MEM_VALID } mem_state_t;
  mem_state_t mem_state;

  logic [31:0]                          mem_lat_addr;
  logic [5:0]                           mem_lat_size;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] mem_rdata;

  assign ex_mem_valid = (mem_state == MEM_VALID);
  assign ex_mem_data  = mem_rdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_state <= MEM_IDLE;
    end else begin
      case (mem_state)
        MEM_IDLE: begin
          if (ex_mem_req) begin
            mem_lat_addr <= ex_mem_start_addr;
            mem_lat_size <= ex_mem_size_bytes;
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
  // Task: run one vector, compare against golden, print one result row
  //------------------------------------------------------------------------
  int pass_count;
  int fail_count;

  task automatic run_vector(
    input int    slot,
    input int    vec_id,
    input logic [7:0]  g_ma,
    input logic [63:0] g_ex,
    input logic [63:0] g_ex2
  );
    automatic int cycles  = 0;
    automatic int timeout = 0;
    automatic logic ma_ok, ex_ok, ex2_ok;

    // Point DUT to this vector's slot in fake_mem
    input_addr = INPUT_BASE + slot * VEC_STRIDE;

    // 2 idle cycles to ensure FSM is in IDLE after previous run
    repeat(2) @(posedge clk);

    // Pulse start
    @(posedge clk); start = 1'b1;
    @(posedge clk); start = 1'b0;

    // Wait for done (timeout = 5000 cycles)
    cycles  = 0;
    timeout = 0;
    while (!done && timeout < 5000) begin
      @(posedge clk);
      timeout++;
      cycles++;
    end

    if (timeout >= 5000) begin
      $display("  vec %3d | TIMEOUT — done never asserted", vec_id);
      fail_count++;
      return;
    end

    ma_ok  = (min_alpha_out === g_ma);
    ex_ok  = (ex_out        === g_ex);
    ex2_ok = (ex2_out       === g_ex2);

    $display("  %3d | 0x%02h %s | 0x%016h %s | 0x%016h %s | %s | %0d cyc",
      vec_id,
      min_alpha_out, ma_ok  ? "OK" : "NG",
      ex_out,        ex_ok  ? "OK" : "NG",
      ex2_out,       ex2_ok ? "OK" : "NG",
      (ma_ok && ex_ok && ex2_ok) ? "PASS" : "FAIL",
      cycles
    );

    if (ma_ok && ex_ok && ex2_ok) pass_count++;
    else                          fail_count++;
  endtask

  //------------------------------------------------------------------------
  // Stimulus
  //------------------------------------------------------------------------
  initial begin
    pass_count = 0;
    fail_count = 0;

    rst_n        = 1'b0;
    start        = 1'b0;
    shared_addr  = SHARED_BASE;
    input_addr   = INPUT_BASE;
    num_channels = 32'd384;
    global_zp    = 32'd128;

    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    repeat(2) @(posedge clk);

    $display("");
    $display("=== EX_EX2 MULTI-VECTOR TESTBENCH ===");
    $display("  Vec | min_alpha       | ex                       | ex2                      | result | cycles");
    $display("  ----|-----------------|--------------------------|--------------------------|--------|-------");

    // slot, vec_id, golden min_alpha, golden ex, golden ex2
    run_vector( 0,   0, 8'hfc, 64'h000000000000010c, 64'h000000000007b842);
    run_vector( 1,   1, 8'hfc, 64'hffffffffffffefd2, 64'h0000000000051aa0);
    run_vector( 2,   2, 8'hfc, 64'hfffffffffffff04a, 64'h000000000004ee5f);
    run_vector( 3,  10, 8'hfc, 64'hfffffffffffff215, 64'h000000000004be52);
    run_vector( 4,  30, 8'hfc, 64'hfffffffffffff596, 64'h0000000000051237);
    run_vector( 5,  50, 8'hfc, 64'hfffffffffffff677, 64'h000000000004d36d);
    run_vector( 6,  75, 8'hfc, 64'hfffffffffffff6e8, 64'h000000000005c1be);
    run_vector( 7, 100, 8'hfc, 64'hfffffffffffffdef, 64'h0000000000045ef4);
    run_vector( 8, 125, 8'hfc, 64'hfffffffffffffbc8, 64'h00000000000628d2);
    run_vector( 9, 150, 8'hfc, 64'hfffffffffffffbcc, 64'h000000000004e1f5);
    run_vector(10, 175, 8'hfc, 64'hfffffffffffff4d5, 64'h000000000004bd8b);
    run_vector(11, 190, 8'hfc, 64'hfffffffffffff628, 64'h0000000000049fdd);
    run_vector(12, 193, 8'hfc, 64'hfffffffffffff6ed, 64'h0000000000053c7b);
    run_vector(13, 195, 8'hfc, 64'hfffffffffffffaea, 64'h0000000000055db6);
    run_vector(14, 196, 8'hfc, 64'hfffffffffffffd46, 64'h00000000000585fd);

    $display("  ----|-----------------|--------------------------|--------------------------|--------|-------");
    $display("  Passed: %0d / %0d", pass_count, pass_count + fail_count);
    if (fail_count == 0)
      $display("  >>> ALL PASS <<<");
    else
      $display("  >>> %0d FAILURE(S) <<<", fail_count);
    $display("");

    $finish;
  end

  initial begin
    $dumpfile("/tmp/tb_ex_ex2.vcd");
    $dumpvars(0, tb_ex_ex2);
  end

endmodule
