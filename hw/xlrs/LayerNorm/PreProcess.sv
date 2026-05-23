module preprocess_stage (
  input  logic clk,
  input  logic rst_n,
  input  logic start,

  input  logic [31:0] shared_addr,
  input  logic [31:0] num_channels,

  output logic done
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      done <= 1'b0;
    else
      done <= start;
  end

endmodule