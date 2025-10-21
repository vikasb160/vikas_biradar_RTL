`timescale 1ns/1ps

module tb_uart_loopback;

  localparam int DATA_WIDTH   = 8;
  localparam real CLK_PERIOD  = 8.0;        // ns (125 MHz)
  localparam int PRESCALE     = 1;
  localparam int BIT_CYCLES   = (PRESCALE << 3);

  reg                     clk = 1'b0;
  reg                     rst = 1'b1;

  // AXIS IN (to TX)
  reg  [DATA_WIDTH-1:0]   s_axis_tdata = '0;
  reg                     s_axis_tvalid = 1'b0;
  wire                    s_axis_tready;

  // AXIS OUT (from RX)
  wire [DATA_WIDTH-1:0]   m_axis_tdata;
  wire                    m_axis_tvalid;
  reg                     m_axis_tready = 1'b1;

  // UART pins (loopback)
  wire                    txd;
  wire                    rxd;
  assign rxd = txd;

  // Status
  wire                    tx_busy, rx_busy;
  wire                    rx_overrun_error, rx_frame_error;

  reg [15:0]              prescale = PRESCALE;

  always #(CLK_PERIOD/2.0) clk = ~clk;

  uart #(
    .DATA_WIDTH(DATA_WIDTH)
  ) dut (
    .clk(clk),
    .rst(rst),

    // TX AXIS
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),

    // RX AXIS
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),

    // UART pins
    .rxd(rxd),
    .txd(txd),

    // status
    .tx_busy(tx_busy),
    .rx_busy(rx_busy),
    .rx_overrun_error(rx_overrun_error),
    .rx_frame_error(rx_frame_error),

    // timing
    .prescale(prescale)
  );

  task automatic axis_send_byte(input [7:0] b);
    begin
      @(posedge clk);
      wait (s_axis_tready);
      s_axis_tdata  <= b;
      s_axis_tvalid <= 1'b1;
      @(posedge clk);
      s_axis_tvalid <= 1'b0;
    end
  endtask

  task automatic axis_send_vec(input int n, input reg [7:0] vec[]);
    int i;
    begin
      for (i = 0; i < n; i++) begin
        axis_send_byte(vec[i]);
        repeat (2) @(posedge clk);
      end
    end
  endtask

  task automatic axis_recv_n(input int n, output reg [7:0] buf[]);
    int idx;
    begin
      idx = 0;
      while (idx < n) begin
        @(posedge clk);
        if (m_axis_tvalid && m_axis_tready) begin
          buf[idx] = m_axis_tdata;
          idx++;
        end
      end
    end
  endtask

  task automatic check_equal(
    input string tag,
    input int n,
    input reg [7:0] exp[],
    input reg [7:0] got[]
  );
    int i;
    begin
      for (i = 0; i < n; i++) begin
        if (got[i] !== exp[i]) begin
          $display("%s mismatch at %0d: exp=%02x got=%02x", tag, i, exp[i], got[i]);
          $fatal(1, "Mismatch");
        end
      end
      $display("%s: PASS (%0d bytes)", tag, n);
    end
  endtask

  initial begin
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);

    reg [7:0] T1 [0:8];
    T1[0]=8'h00; T1[1]=8'h01; T1[2]=8'h02; T1[3]=8'h04; T1[4]=8'h08;
    T1[5]=8'h10; T1[6]=8'h20; T1[7]=8'h40; T1[8]=8'h80;

    reg [7:0] R1 [0:8];

    axis_send_vec(9, T1);
    axis_recv_n(9, R1);
    check_equal("LOOP Test 1", 9, T1, R1);

    reg [7:0] T2 [0:8];
    T2[0]=8'h00; T2[1]=8'h01; T2[2]=8'h03; T2[3]=8'h07; T2[4]=8'h0F;
    T2[5]=8'h1F; T2[6]=8'h3F; T2[7]=8'h7F; T2[8]=8'hFF;

    reg [7:0] R2 [0:8];

    axis_send_vec(9, T2);
    axis_recv_n(9, R2);
    check_equal("LOOP Test 2", 9, T2, R2);

    if (rx_overrun_error) $fatal(1, "Unexpected overrun");
    if (rx_frame_error)   $fatal(1, "Unexpected frame error");

    $display("All LOOPBACK tests passed.");
    #1000 $finish;
  end

endmodule
