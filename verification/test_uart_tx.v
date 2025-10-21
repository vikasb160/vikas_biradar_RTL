`timescale 1ns/1ps

module test_uart_tx;

  // ---- Config ----
  parameter DATA_WIDTH      = 8;
  parameter CLK_PERIOD_NS   = 8;   // 125 MHz
  parameter PRESCALE        = 1;   // 1 -> one bit = 8 clocks
  localparam integer BIT_CYCLES = (PRESCALE << 3);

  // ---- DUT I/O ----
  reg                     clk = 1'b0;
  reg                     rst = 1'b1;

  reg  [DATA_WIDTH-1:0]   s_axis_tdata = 0;
  reg                     s_axis_tvalid = 1'b0;
  wire                    s_axis_tready;

  wire                    txd;
  wire                    busy;

  reg  [15:0]             prescale = PRESCALE;

  // ---- Clock ----
  always #(CLK_PERIOD_NS/2) clk = ~clk;

  // ---- DUT ----
  uart_tx #(
    .DATA_WIDTH(DATA_WIDTH)
  ) dut (
    .clk(clk),
    .rst(rst),

    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),

    .txd(txd),
    .busy(busy),

    .prescale(prescale)
  );

  // ---- Simple UART sink (samples txd at bit centers, LSB-first) ----
  task uart_rx_byte;
    output [7:0] b;
    integer i, k;
    begin
      // wait for start bit (falling)
      @(posedge clk);
      while (txd === 1'b1) @(posedge clk);

      // move to middle of start bit
      for (k = 0; k < (BIT_CYCLES/2); k = k + 1) @(posedge clk);

      // optional confirm start still low
      // if (txd !== 1'b0) begin $display("Bad start bit"); $finish; end

      // sample 8 data bits at bit centers
      b = 8'h00;
      for (i = 0; i < DATA_WIDTH; i = i + 1) begin
        for (k = 0; k < BIT_CYCLES; k = k + 1) @(posedge clk);
        b[i] = txd; // LSB first
      end

      // stop bit
      for (k = 0; k < BIT_CYCLES; k = k + 1) @(posedge clk);
      // if (txd !== 1'b1) begin $display("Bad stop bit"); $finish; end
    end
  endtask

  // Send one byte on AXI-Stream (one-beat frame)
  task axis_send_byte;
    input [7:0] b;
    begin
      @(posedge clk);
      // ready-when-idle: wait until DUT asserts ready
      while (!s_axis_tready) @(posedge clk);
      s_axis_tdata  <= b;
      s_axis_tvalid <= 1'b1;
      @(posedge clk);               // handshake happens here
      s_axis_tvalid <= 1'b0;        // TX deasserts ready in next cycle
    end
  endtask

  // ---- Test vectors / capture buffers ----
  reg [7:0] T1 [0:8];
  reg [7:0] R1 [0:8];

  reg [7:0] T2 [0:8];
  reg [7:0] R2 [0:8];

  integer i, j; // shared indices

  // ---- Stimulus ----
  initial begin
    // reset
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);

    // ------------------ Test 1 (walk) ------------------
    T1[0]=8'h00; T1[1]=8'h01; T1[2]=8'h02; T1[3]=8'h04; T1[4]=8'h08;
    T1[5]=8'h10; T1[6]=8'h20; T1[7]=8'h40; T1[8]=8'h80;

    fork
      // Sender
      begin : SENDER1
        for (i = 0; i < 9; i = i + 1) begin
          axis_send_byte(T1[i]);
          // small gap between frames
          repeat (2) @(posedge clk);
        end
      end

      // Line sniffer (receiver)
      begin : RECV1
        for (j = 0; j < 9; j = j + 1) begin
          uart_rx_byte(R1[j]);
        end
      end
    join

    // Check equality
    for (i = 0; i < 9; i = i + 1) begin
      if (R1[i] !== T1[i]) begin
        $display("TX Test 1 mismatch at %0d: exp=%02x got=%02x", i, T1[i], R1[i]);
        $finish;
      end
    end
    $display("TX Test 1: PASS");

    // ------------------ Test 2 (walk-2) ------------------
    T2[0]=8'h00; T2[1]=8'h01; T2[2]=8'h03; T2[3]=8'h07; T2[4]=8'h0F;
    T2[5]=8'h1F; T2[6]=8'h3F; T2[7]=8'h7F; T2[8]=8'hFF;

    fork
      // Sender
      begin : SENDER2
        for (i = 0; i < 9; i = i + 1) begin
          axis_send_byte(T2[i]);
          repeat (2) @(posedge clk);
        end
      end

      // Line sniffer (receiver)
      begin : RECV2
        for (j = 0; j < 9; j = j + 1) begin
          uart_rx_byte(R2[j]);
        end
      end
    join

    // Check equality
    for (i = 0; i < 9; i = i + 1) begin
      if (R2[i] !== T2[i]) begin
        $display("TX Test 2 mismatch at %0d: exp=%02x got=%02x", i, T2[i], R2[i]);
        $finish;
      end
    end
    $display("TX Test 2: PASS");

    $display("All TX tests passed.");
    #1000 $finish;
  end

endmodule
