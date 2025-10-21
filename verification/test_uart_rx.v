`timescale 1ns/1ps

module test_uart_rx;

  // ---- Config ----
  parameter DATA_WIDTH       = 8;
  parameter CLK_PERIOD_NS    = 8;   // 125 MHz
  parameter PRESCALE         = 1;   // 1 -> bit time = 8 clocks
  localparam BIT_CYCLES      = (PRESCALE << 3);

  // ---- DUT I/O ----
  reg                     clk = 1'b0;
  reg                     rst = 1'b1;

  wire [DATA_WIDTH-1:0]   m_axis_tdata;
  wire                    m_axis_tvalid;
  reg                     m_axis_tready = 1'b1;

  reg                     rxd = 1'b1;       // idle high
  wire                    busy;
  wire                    overrun_error;
  wire                    frame_error;

  reg  [15:0]             prescale = PRESCALE;

  // ---- Clock ----
  always #(CLK_PERIOD_NS/2) clk = ~clk;

  // ---- DUT ----
  uart_rx #(
    .DATA_WIDTH(DATA_WIDTH)
  ) dut (
    .clk(clk),
    .rst(rst),

    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),

    .rxd(rxd),

    .busy(busy),
    .overrun_error(overrun_error),
    .frame_error(frame_error),

    .prescale(prescale)
  );

  // ---- Simple UART source (drives rxd LSB-first at bit centers) ----
  task uart_tx_byte;
    input [7:0] b;
    integer i, k;
    begin
      // start bit
      rxd <= 1'b0;
      for (k = 0; k < BIT_CYCLES; k = k + 1) @(posedge clk);

      // data bits LSB->MSB
      for (i = 0; i < DATA_WIDTH; i = i + 1) begin
        rxd <= b[i];
        for (k = 0; k < BIT_CYCLES; k = k + 1) @(posedge clk);
      end

      // stop bit
      rxd <= 1'b1;
      for (k = 0; k < BIT_CYCLES; k = k + 1) @(posedge clk);
    end
  endtask

  // ---- Test vectors / capture buffers ----
  reg [7:0] T1 [0:8];
  reg [7:0] R1 [0:8];

  reg [7:0] T2 [0:8];
  reg [7:0] R2 [0:8];

  // ---- Stimulus ----
  integer i;  // re-used loop index

  initial begin
    // reset
    rxd <= 1'b1;
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);

    // ------------------ Test 1 (walk) ------------------
    T1[0]=8'h00; T1[1]=8'h01; T1[2]=8'h02; T1[3]=8'h04; T1[4]=8'h08;
    T1[5]=8'h10; T1[6]=8'h20; T1[7]=8'h40; T1[8]=8'h80;

    // Run sender and receiver concurrently
    fork
      // sender
      begin: SENDER1
        for (i = 0; i < 9; i = i + 1) begin
          uart_tx_byte(T1[i]);
          @(posedge clk);
        end
      end

      // receiver
      begin: RECEIVER1
        integer idx1;
        idx1 = 0;
        while (idx1 < 9) begin
          @(posedge clk);
          if (m_axis_tvalid && m_axis_tready) begin
            R1[idx1] = m_axis_tdata;
            idx1 = idx1 + 1;
          end
        end
      end
    join

    // Check equality
    for (i = 0; i < 9; i = i + 1) begin
      if (R1[i] !== T1[i]) begin
        $display("RX Test 1 mismatch at %0d: exp=%02x got=%02x", i, T1[i], R1[i]);
        $finish;
      end
    end
    $display("RX Test 1: PASS");

    // ------------------ Test 2 (walk-2) ------------------
    T2[0]=8'h00; T2[1]=8'h01; T2[2]=8'h03; T2[3]=8'h07; T2[4]=8'h0F;
    T2[5]=8'h1F; T2[6]=8'h3F; T2[7]=8'h7F; T2[8]=8'hFF;

    fork
      // sender
      begin: SENDER2
        for (i = 0; i < 9; i = i + 1) begin
          uart_tx_byte(T2[i]);
          @(posedge clk);
        end
      end

      // receiver
      begin: RECEIVER2
        integer idx2;
        idx2 = 0;
        while (idx2 < 9) begin
          @(posedge clk);
          if (m_axis_tvalid && m_axis_tready) begin
            R2[idx2] = m_axis_tdata;
            idx2 = idx2 + 1;
          end
        end
      end
    join

    // Check equality
    for (i = 0; i < 9; i = i + 1) begin
      if (R2[i] !== T2[i]) begin
        $display("RX Test 2 mismatch at %0d: exp=%02x got=%02x", i, T2[i], R2[i]);
        $finish;
      end
    end
    $display("RX Test 2: PASS");

    // Final sanity
    if (frame_error)   begin $display("Unexpected frame_error pulse");   $finish; end
    if (overrun_error) begin $display("Unexpected overrun_error pulse"); $finish; end

    $display("All RX tests passed.");
    #1000 $finish;
  end

endmodule
