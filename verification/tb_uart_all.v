`timescale 1ns/1ps

module tb_uart_loopback;

  // -------- Parameters --------
  localparam DATA_WIDTH = 8;
  localparam PRESCALE   = 8;   // both TX/RX use this; bit time = PRESCALE*8 cycles
  localparam N1         = 9;
  localparam N2         = 9;

  // Derived timing & watchdog
  localparam BITS_PER_FRAME   = DATA_WIDTH + 2;            // start + data + stop
  localparam CYCLES_PER_BIT   = (PRESCALE << 3);           // *8
  localparam CYCLES_PER_FRAME = BITS_PER_FRAME * CYCLES_PER_BIT;

  // Global timeout is now very large; per-phase budgets prevent stalling
  localparam TIMEOUT_CYCLES   = 2000 * CYCLES_PER_FRAME;

  // Clock period (ns)
  real CLK_PERIOD;
  initial CLK_PERIOD = 8.0; // 125 MHz
  reg clk = 1'b0;
  always #(CLK_PERIOD/2.0) clk = ~clk;

  // Reset
  reg rst = 1'b1;

  // AXIS IN (to TX)
  reg  [DATA_WIDTH-1:0] s_axis_tdata  = {DATA_WIDTH{1'b0}};
  reg                   s_axis_tvalid = 1'b0;
  wire                  s_axis_tready;

  // AXIS OUT (from RX)
  wire [DATA_WIDTH-1:0] m_axis_tdata;
  wire                  m_axis_tvalid;
  reg                   m_axis_tready = 1'b1;

  // UART pins with injection mux for RX-only tests
  wire txd;
  reg  rxd_drv_en  = 1'b0;   // 0: loopback (txd), 1: bench drives rxd_drv_val
  reg  rxd_drv_val = 1'b1;   // when rxd_drv_en=1, this is the line level
  wire rxd = rxd_drv_en ? rxd_drv_val : txd;

  // Status
  wire tx_busy, rx_busy;
  wire rx_overrun_error, rx_frame_error;

  reg [15:0] prescale = PRESCALE;

  // DUT
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

  // -------- Error accumulator (run-to-completion) --------
  integer errors = 0;

  // -------- Global test vectors (declare before tasks) --------
  reg [7:0] T1 [0:N1-1];
  reg [7:0] T2 [0:N2-1];

  // -------- LOOPBACK RX monitor --------
  reg [7:0] RX [0:2047];
  integer   rx_cnt = 0;

  reg rx_overrun_seen = 1'b0;
  reg rx_frame_seen   = 1'b0;

  always @(posedge clk) begin
    if (rst) begin
      rx_cnt          <= 0;
      rx_overrun_seen <= 1'b0;
      rx_frame_seen   <= 1'b0;
    end else begin
      if (!rxd_drv_en) begin
        // Only count loopback when we're not overriding rxd
        if (m_axis_tvalid && m_axis_tready) begin
          RX[rx_cnt] <= m_axis_tdata;
          rx_cnt     <= rx_cnt + 1;
        end
        if (rx_overrun_error) rx_overrun_seen <= 1'b1;
        if (rx_frame_error)   rx_frame_seen   <= 1'b1;
      end
    end
  end

  // -------- TX helpers (robust handshake) --------
  task axis_send_byte;
    input [7:0] b;
    begin
      // Wait until TX advertises ready=1 (bounded)
      begin : WAIT_READY
        integer budget;
        budget = 4*CYCLES_PER_FRAME;
        while (!s_axis_tready && budget > 0) begin @(posedge clk); budget = budget - 1; end
        if (!s_axis_tready) begin
          $display("[TX_TIMEOUT_READY] TX did not assert s_axis_tready");
          errors = errors + 1;
        end
      end

      // Drive VALID and DATA; hold VALID until we see READY drop (accept)
      s_axis_tdata  <= b;
      s_axis_tvalid <= 1'b1;
      @(posedge clk);

      // Bounded accept wait
      begin : WAIT_ACCEPT
        integer budget;
        budget = 4*CYCLES_PER_FRAME;
        while (s_axis_tready && budget > 0) begin @(posedge clk); budget = budget - 1; end
        if (s_axis_tready) begin
          $display("[TX_TIMEOUT_ACCEPT] TX did not accept byte");
          errors = errors + 1;
        end
      end

      // Deassert VALID after acceptance
      s_axis_tvalid <= 1'b0;
    end
  endtask

  task axis_send_vec_T;
    input integer count;
    input integer sel; // 0 -> T1, 1 -> T2
    integer i;
    begin
      for (i = 0; i < count; i = i + 1) begin
        if (sel == 0) axis_send_byte(T1[i]);
        else          axis_send_byte(T2[i]);
        @(posedge clk);
      end
    end
  endtask

  // -------- Checkers (loopback) --------
  task check_equal_block_T1;
    input integer base;
    input integer count;
    integer i;
    integer local_err;
    begin
      local_err = 0;
      for (i = 0; i < count; i = i + 1) begin
        if (RX[base+i] !== T1[i]) begin
          $display("LOOP Test 1 mismatch at %0d: exp=%02x got=%02x", i, T1[i], RX[base+i]);
          errors = errors + 1; local_err = local_err + 1;
        end
      end
      if (local_err==0) $display("LOOP Test 1: PASS (%0d bytes)", count);
    end
  endtask

  task check_equal_block_T2;
    input integer base;
    input integer count;
    integer i;
    integer local_err;
    begin
      local_err = 0;
      for (i = 0; i < count; i = i + 1) begin
        if (RX[base+i] !== T2[i]) begin
          $display("LOOP Test 2 mismatch at %0d: exp=%02x got=%02x", i, T2[i], RX[base+i]);
          errors = errors + 1; local_err = local_err + 1;
        end
      end
      if (local_err==0) $display("LOOP Test 2: PASS (%0d bytes)", count);
    end
  endtask

  // -------- Watchdog (won't fire in normal runs) --------
  integer wd_cnt = 0;
  always @(posedge clk) begin
    if (rst) wd_cnt <= 0;
    else     wd_cnt <= wd_cnt + 1;
    if (wd_cnt > TIMEOUT_CYCLES) begin
      $display("ERROR: Test timeout after %0d cycles", TIMEOUT_CYCLES);
      errors = errors + 1;
      $display("SUMMARY: errors=%0d", errors);
      $finish;
    end
  end
  task wd_kick; begin wd_cnt = 0; end endtask

  // =================================================================
  // ====================== RX-only helper TX =========================
  // Drive rxd directly (disconnect loopback via rxd_drv_en=1)
  // =================================================================
  // perfect UART byte on rxd (LSB-first at bit edges)
  task uart_tx_byte_on_rxd;
    input [7:0] b;
    integer i, k;
    begin
      // start
      rxd_drv_val <= 1'b0;
      for (k = 0; k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
      // data bits
      for (i = 0; i < DATA_WIDTH; i = i + 1) begin
        rxd_drv_val <= b[i];
        for (k = 0; k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
      end
      // stop
      rxd_drv_val <= 1'b1;
      for (k = 0; k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
    end
  endtask

  // skewed-first-bit for BUG1 timing test: keep start level for 'skew' cycles
  task uart_tx_byte_on_rxd_skew_first;
    input [7:0] b;
    input integer skew; // e.g., 2 cycles
    integer i, k;
    begin
      // start
      rxd_drv_val <= 1'b0;
      for (k = 0; k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
      // first data bit (LSB) skewed
      for (k = 0; k < skew; k = k + 1) @(posedge clk); // hold start value
      rxd_drv_val <= b[0];
      for (k = skew; k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
      // remaining bits
      for (i = 1; i < DATA_WIDTH; i = i + 1) begin
        rxd_drv_val <= b[i];
        for (k = 0; k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
      end
      // stop
      rxd_drv_val <= 1'b1;
      for (k = 0; k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
    end
  endtask

  // =================================================================
  // =================== TX line sniffer (monitor) ====================
  // Samples txd mid-bit; checks stop bit mid (BUG2) and returns byte.
  // Includes bounded waits so it never stalls.
  // =================================================================
  task sniff_txd_byte;
  output [7:0] b;
  integer i, k, budget;
  reg prev, seen_edge;
  begin
    b = 8'h00;

    // Ensure we start from idle-high (don’t arm mid-frame)
    budget = 4*CYCLES_PER_FRAME;
    while (txd !== 1'b1 && budget > 0) begin @(posedge clk); budget = budget - 1; end
    if (budget == 0) begin
      $display("[TX_TIMEOUT_WAIT_START] no idle-high before start");
      errors = errors + 1;
      return;
    end

    // Detect a real 1->0 start edge
    prev      = txd;
    seen_edge = 1'b0;
    budget    = 4*CYCLES_PER_FRAME;
    while (!seen_edge && budget > 0) begin
      @(posedge clk);
      seen_edge = (prev === 1'b1) && (txd === 1'b0);
      prev      = txd;
      budget    = budget - 1;
    end
    if (!seen_edge) begin
      $display("[TX_TIMEOUT_WAIT_START] no start edge on txd");
      errors = errors + 1;
      return;
    end

    // move to middle of start bit
    for (k = 0; k < (CYCLES_PER_BIT/2); k = k + 1) @(posedge clk);

    // sample data bits in centers
    for (i = 0; i < DATA_WIDTH; i = i + 1) begin
      for (k = 0; k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
      b[i] = txd; // LSB first
    end

    // stop bit center check
    for (k = 0; k < (CYCLES_PER_BIT/2); k = k + 1) @(posedge clk);
    if (txd !== 1'b1) begin
      $display("[BUG2_STOP_LEVEL] stop mid-bit not high");
      errors = errors + 1;
    end
    for (k = (CYCLES_PER_BIT/2); k < CYCLES_PER_BIT; k = k + 1) @(posedge clk);
  end
endtask

  // -------- Stimulus --------
  integer base0, base1;

  // Extra arrays for RX-only and TX-only suites
  reg [7:0] R1_rxonly [0:8];
  reg [7:0] R2_rxonly [0:8];
  reg [7:0] RB1_rxonly[0:7];

  reg [7:0] RT1_txonly [0:8];
  reg [7:0] RT2_txonly [0:8];

  integer i, j;

  // bounded wait helper for loopback “wait for N bytes”
  task wait_rx_bytes_or_flag;
    input integer target_total;   // base + expected
    input integer budget_cycles;  // max cycles to wait
    input [127:0] tag;            // message tag
    integer budget;
    begin
      budget = budget_cycles;
      while ((rx_cnt < target_total) && (budget > 0)) begin
        @(posedge clk); budget = budget - 1;
      end
      if (rx_cnt < target_total) begin
        $display("[%0s] expected %0d more bytes, got %0d total", tag, target_total, rx_cnt);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    // Reset
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);

    // Initialize vectors
    T1[0]=8'h00; T1[1]=8'h01; T1[2]=8'h02; T1[3]=8'h04; T1[4]=8'h08;
    T1[5]=8'h10; T1[6]=8'h20; T1[7]=8'h40; T1[8]=8'h80;

    T2[0]=8'h00; T2[1]=8'h01; T2[2]=8'h03; T2[3]=8'h07; T2[4]=8'h0F;
    T2[5]=8'h1F; T2[6]=8'h3F; T2[7]=8'h7F; T2[8]=8'hFF;

    // ====================== LOOPBACK TESTS (as in reference, but bounded waits) ======================
    wd_kick();
    base0 = rx_cnt;
    axis_send_vec_T(N1, 0);
    wait_rx_bytes_or_flag(base0 + N1, 8*CYCLES_PER_FRAME*N1, "LOOP_T1_WAIT");
    if ((rx_cnt - base0) >= N1) check_equal_block_T1(base0, N1);

    base1 = rx_cnt;
    axis_send_vec_T(N2, 1);
    wait_rx_bytes_or_flag(base1 + N2, 8*CYCLES_PER_FRAME*N2, "LOOP_T2_WAIT");
    if ((rx_cnt - base1) >= N2) check_equal_block_T2(base1, N2);

    if (rx_overrun_seen) begin
      $display("ERROR: Unexpected RX overrun");
      errors = errors + 1;
    end
    if (rx_frame_seen) begin
      $display("ERROR: Unexpected RX frame error");
      errors = errors + 1;
    end

    if (errors==0) $display("All LOOPBACK tests passed.");
    wd_kick();

    // ====================== RX-ONLY TESTS ======================
    // Disconnect loopback and drive rxd directly
    rxd_drv_en  <= 1'b1;
    rxd_drv_val <= 1'b1;
    @(posedge clk);

    // --- RX BUG2 (bit order) — Test A: walking-1 ---
    fork
      begin : RXONLY_SEND_A
        for (i=0;i<9;i=i+1) begin
          uart_tx_byte_on_rxd(T1[i]);
          @(posedge clk);
        end
      end
      begin : RXONLY_RECV_A
        integer idx;
        integer idle;
        idx  = 0;
        idle = 0;
        while (idx<9) begin
          @(posedge clk);
          if (m_axis_tvalid && m_axis_tready) begin
            R1_rxonly[idx] = m_axis_tdata;
            idx  = idx + 1;
            idle = 0;
          end else begin
            idle = idle + 1;
            if (idle > 6*CYCLES_PER_FRAME) begin
              $display("[RX_TIMEOUT_A] no byte %0d within budget", idx);
              errors = errors + 1;
              R1_rxonly[idx] = 8'h00; // placeholder
              idx  = idx + 1;
              idle = 0;
            end
          end
        end
      end
    join
    begin : RXONLY_CHK_A
      integer e;
      e = 0;
      for (i=0;i<9;i=i+1) begin
        if (R1_rxonly[i] !== T1[i]) begin
          $display("[BUG2_BIT_ORDER] mismatch A idx %0d: exp=%02x got=%02x", i, T1[i], R1_rxonly[i]);
          errors = errors + 1; e = e + 1;
        end
      end
      if (e==0) $display("RX-only Test A (bit-order walking-1): PASS");
    end

    // --- RX BUG2 (bit order) — Test B: accum masks ---
    fork
      begin : RXONLY_SEND_B
        for (i=0;i<9;i=i+1) begin
          uart_tx_byte_on_rxd(T2[i]);
          @(posedge clk);
        end
      end
      begin : RXONLY_RECV_B
        integer idx;
        integer idle;
        idx  = 0;
        idle = 0;
        while (idx<9) begin
          @(posedge clk);
          if (m_axis_tvalid && m_axis_tready) begin
            R2_rxonly[idx] = m_axis_tdata;
            idx  = idx + 1;
            idle = 0;
          end else begin
            idle = idle + 1;
            if (idle > 6*CYCLES_PER_FRAME) begin
              $display("[RX_TIMEOUT_B] no byte %0d within budget", idx);
              errors = errors + 1;
              R2_rxonly[idx] = 8'h00;
              idx  = idx + 1;
              idle = 0;
            end
          end
        end
      end
    join
    begin : RXONLY_CHK_B
      integer e;
      e = 0;
      for (i=0;i<9;i=i+1) begin
        if (R2_rxonly[i] !== T2[i]) begin
          $display("[BUG2_BIT_ORDER] mismatch B idx %0d: exp=%02x got=%02x", i, T2[i], R2_rxonly[i]);
          errors = errors + 1; e = e + 1;
        end
      end
      if (e==0) $display("RX-only Test B (bit-order accum): PASS");
    end

    // --- RX BUG1 (first-bit timing) — skew first data bit by 1 cycles ---
    fork
      begin : RXONLY_SEND_C
        for (i=0;i<8;i=i+1) begin
          uart_tx_byte_on_rxd_skew_first(8'h01, 1); // LSB=1, skew=1 cycles
          @(posedge clk);
        end
      end
      begin : RXONLY_RECV_C
        integer idx;
        integer idle;
        idx  = 0;
        idle = 0;
        while (idx<8) begin
          @(posedge clk);
          if (m_axis_tvalid && m_axis_tready) begin
            RB1_rxonly[idx] = m_axis_tdata;
            idx  = idx + 1;
            idle = 0;
          end else begin
            idle = idle + 1;
            if (idle > 6*CYCLES_PER_FRAME) begin
              $display("[RX_TIMEOUT_C] no byte %0d within budget", idx);
              errors = errors + 1;
              RB1_rxonly[idx] = 8'h00;
              idx  = idx + 1;
              idle = 0;
            end
          end
        end
      end
    join
    begin : RXONLY_CHK_C
      integer e;
      e = 0;
      for (i=0;i<8;i=i+1) begin
        if (RB1_rxonly[i] !== 8'h01) begin
          $display("[BUG1_TIMING] first-bit too-early: exp=01 got=%02x at %0d", RB1_rxonly[i], i);
          errors = errors + 1; e = e + 1;
        end
      end
      if (e==0) $display("RX-only Test C (first-bit timing): PASS");
    end

    // Reconnect loopback
    rxd_drv_en  <= 1'b0;
    @(posedge clk);
    wd_kick();

// Ensure TX is idle before TX-only tests
begin : WAIT_TX_IDLE
  integer budget;
  budget = 4*CYCLES_PER_FRAME;
  while (tx_busy && budget > 0) begin @(posedge clk); budget = budget - 1; end
end

    // ====================== TX-ONLY TESTS (sniffer) ======================
    // --- TX BUG1 (shift/output order) — Test 1: walking-1 ---
    fork
      begin : TXONLY_SEND1
        for (i=0;i<9;i=i+1) begin
          axis_send_byte(T1[i]);
          repeat (2) @(posedge clk);
        end
      end
      begin : TXONLY_SNIFF1
        for (j=0;j<9;j=j+1) begin
          sniff_txd_byte(RT1_txonly[j]);
        end
      end
    join
    begin : TXONLY_CHK1
      integer e;
      e = 0;
      for (i=0;i<9;i=i+1) begin
        if (RT1_txonly[i] !== T1[i]) begin
          $display("[BUG1_SHIFT_DIR] mismatch T1 idx %0d: exp=%02x got=%02x", i, T1[i], RT1_txonly[i]);
          errors = errors + 1; e = e + 1;
        end
      end
      if (e==0) $display("TX-only Test 1 (walking-1): PASS");
    end

    // --- TX BUG1 (shift/output order) — Test 2: accum masks ---
    fork
      begin : TXONLY_SEND2
        for (i=0;i<9;i=i+1) begin
          axis_send_byte(T2[i]);
          repeat (2) @(posedge clk);
        end
      end
      begin : TXONLY_SNIFF2
        for (j=0;j<9;j=j+1) begin
          sniff_txd_byte(RT2_txonly[j]);
        end
      end
    join
    begin : TXONLY_CHK2
      integer e;
      e = 0;
      for (i=0;i<9;i=i+1) begin
        if (RT2_txonly[i] !== T2[i]) begin
          $display("[BUG1_SHIFT_DIR] mismatch T2 idx %0d: exp=%02x got=%02x", i, T2[i], RT2_txonly[i]);
          errors = errors + 1; e = e + 1;
        end
      end
      if (e==0) $display("TX-only Test 2 (accum masks): PASS");
    end

    // ====================== Summary ======================
    if (errors==0) $display("SUMMARY: errors=0 (All LOOPBACK/RX/TX tests PASSED)");
    else           $display("SUMMARY: errors=%0d (see tagged FAIL lines)", errors);

    #200 @(posedge clk);
    $finish;
  end

endmodule
