import xbox_def_pkg::*;

module tb_zp;

  localparam CLK_PERIOD = 10;

  logic clk, rst_n;
  logic start;
  logic [31:0] shared_addr_tb;

  logic                                 zp_mem_req;
  logic [31:0]                          zp_mem_start_addr;
  logic [5:0]                           zp_mem_size_bytes;
  logic                                 zp_mem_valid;
  logic [BYTES_PER_XMEM_LINE-1:0][7:0] zp_mem_data;

  logic [31:0] global_zp_out;
  logic [31:0] gamma_zp_out;
  logic [31:0] beta_zp_out;
  logic        done;

  // 4 KB fake memory: each test uses 256-byte slot (test_id * 0x100)
  logic [7:0] fake_mem [0:4095];

  zp_stage dut (
    .clk               (clk),
    .rst_n             (rst_n),
    .start             (start),
    .shared_addr       (shared_addr_tb),
    .zp_mem_req        (zp_mem_req),
    .zp_mem_start_addr (zp_mem_start_addr),
    .zp_mem_size_bytes (zp_mem_size_bytes),
    .zp_mem_valid      (zp_mem_valid),
    .zp_mem_data       (zp_mem_data),
    .global_zp_out     (global_zp_out),
    .gamma_zp_out      (gamma_zp_out),
    .beta_zp_out       (beta_zp_out),
    .done              (done)
  );

  always #(CLK_PERIOD/2) clk = ~clk;

  //--------------------------------------------------------------------------
  // 3-state read memory model: MEM_IDLE -> MEM_WAIT -> MEM_VALID
  //--------------------------------------------------------------------------
  typedef enum logic [1:0] { MEM_IDLE, MEM_WAIT, MEM_VALID } mem_state_t;
  mem_state_t  mem_state;
  logic [31:0] mem_addr_latch;
  logic [5:0]  mem_size_latch;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_state    <= MEM_IDLE;
      zp_mem_valid <= 1'b0;
      zp_mem_data  <= '0;
    end else begin
      zp_mem_valid <= 1'b0;
      case (mem_state)
        MEM_IDLE: begin
          if (zp_mem_req) begin
            mem_addr_latch <= zp_mem_start_addr;
            mem_size_latch <= zp_mem_size_bytes;
            mem_state      <= MEM_WAIT;
          end
        end
        MEM_WAIT: begin
          for (int k = 0; k < BYTES_PER_XMEM_LINE; k++) begin
            if (k < mem_size_latch)
              zp_mem_data[k] <= fake_mem[mem_addr_latch + k];
            else
              zp_mem_data[k] <= 8'h0;
          end
          mem_state <= MEM_VALID;
        end
        MEM_VALID: begin
          zp_mem_valid <= 1'b1;
          mem_state    <= MEM_IDLE;
        end
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // Test task: load ZP values into fake_mem slot, run DUT, check outputs
  //--------------------------------------------------------------------------
  int pass_count, fail_count;

  task automatic run_test(
    input int test_id,
    input int gzp,    // expected global_zp  (int32)
    input int gmzp,   // expected gamma_zp   (int32, may be negative)
    input int btzp    // expected beta_zp    (int32)
  );
    automatic logic [31:0] base;
    automatic logic [31:0] tmp_g, tmp_gm, tmp_bt;
    automatic int timeout;

    base  = test_id * 32'h100;
    tmp_g  = gzp;
    tmp_gm = gmzp;
    tmp_bt = btzp;

    // Load 12 bytes at base+8: [global_zp LE][gamma_zp LE][beta_zp LE]
    fake_mem[base+8]  = tmp_g[7:0];   fake_mem[base+9]  = tmp_g[15:8];
    fake_mem[base+10] = tmp_g[23:16]; fake_mem[base+11] = tmp_g[31:24];
    fake_mem[base+12] = tmp_gm[7:0];  fake_mem[base+13] = tmp_gm[15:8];
    fake_mem[base+14] = tmp_gm[23:16];fake_mem[base+15] = tmp_gm[31:24];
    fake_mem[base+16] = tmp_bt[7:0];  fake_mem[base+17] = tmp_bt[15:8];
    fake_mem[base+18] = tmp_bt[23:16];fake_mem[base+19] = tmp_bt[31:24];

    shared_addr_tb = base;

    // Pulse start for one cycle
    @(posedge clk); start = 1;
    @(posedge clk); start = 0;

    // Wait for done (timeout 100 cycles)
    timeout = 0;
    while (!done && timeout < 100) begin
      @(posedge clk);
      timeout++;
    end

    if (!done) begin
      $error("[TEST %2d] TIMEOUT: done never asserted", test_id);
      fail_count++;
      return;
    end

    // Check all three outputs
    if (global_zp_out === tmp_g && gamma_zp_out === tmp_gm && beta_zp_out === tmp_bt) begin
      $display("[TEST %2d] PASS  global_zp=%0d  gamma_zp=%0d  beta_zp=%0d",
               test_id, $signed(global_zp_out), $signed(gamma_zp_out), $signed(beta_zp_out));
      pass_count++;
    end else begin
      $error("[TEST %2d] FAIL  global_zp: got=%0d exp=%0d | gamma_zp: got=%0d exp=%0d | beta_zp: got=%0d exp=%0d",
             test_id,
             $signed(global_zp_out),  $signed(tmp_g),
             $signed(gamma_zp_out),   $signed(tmp_gm),
             $signed(beta_zp_out),    $signed(tmp_bt));
      fail_count++;
    end

    // Allow DONE->IDLE (start=0 so one clock is enough) then extra settling
    @(posedge clk);
    repeat(2) @(posedge clk);
  endtask

  //--------------------------------------------------------------------------
  // Stimulus: 15 test cases
  //   shared_addr slot N is at byte address N*0x100 (256 bytes apart)
  //   ZP data lands at slot_base + 8..19 — well within each 256-byte slot
  //--------------------------------------------------------------------------
  initial begin
    clk   = 0;
    rst_n = 0;
    start = 0;
    shared_addr_tb = 32'h0;
    pass_count = 0;
    fail_count = 0;
    for (int i = 0; i < 4096; i++) fake_mem[i] = 8'h0;

    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    //                   id  global_zp  gamma_zp   beta_zp
    run_test( 0,  128,       -2,        146);  // actual model values (SOLE paper)
    run_test( 1,    0,        0,          0);  // all zeros
    run_test( 2,  255,      127,        255);  // near max positives
    run_test( 3,    1,       -1,          1);  // small near-zero
    run_test( 4,  200,     -128,        100);  // mixed
    run_test( 5,   64,       64,         64);  // same value for all three
    run_test( 6,  128,       -2,        146);  // repeat actual — consistency
    run_test( 7,  32767,  32767,      32767);  // int16 max in each field
    run_test( 8, -32768, -32768,     -32768);  // int16 min (negative int32)
    run_test( 9,  100,      -50,        200);  // mixed signs
    run_test(10,   16,      -16,         32);  // small powers of 2
    run_test(11,  255,      255,        255);  // all-bits-set in byte 0
    run_test(12,  128,       -2,        146);  // repeat actual — third time
    run_test(13,  255,     -128,          0);  // edge mix: max, neg, zero
    run_test(14,   42,       -7,         99);  // arbitrary values

    $display("\n=== ZP Testbench: %0d/15 PASS ===", pass_count);
    if (fail_count == 0)
      $display("ALL 15 TESTS PASSED");
    else
      $display("%0d TEST(S) FAILED", fail_count);

    $finish;
  end

endmodule
