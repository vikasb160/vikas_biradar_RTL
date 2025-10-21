# UART Receive RTL (`uart_rx`) Bug Fixes

Identify and correct logical bugs in the **UART Receive RTL (`uart_rx`)** related to **inter-bit sampling timing** and **bit reconstruction order**. These issues distort on-wire data recovery and produce deterministic mismatches in RX and loopback tests.

---

## **Module Overview**

The `uart_rx` block deserializes an **8N1** UART stream into AXI4-Stream bytes using an oversampled, timer-based sampler.

* **Inputs**

  * `clk`, `rst`
  * `rxd` — asynchronous UART input (idle high)
  * `m_axis_tready`
  * `prescale[15:0]` — defines bit period: `T_bit = prescale << 3`

* **Outputs**

  * `m_axis_tdata[DATA_WIDTH-1:0]`, `m_axis_tvalid`
  * `busy`
  * `overrun_error` (1-cycle pulse on output back-pressure overrun)
  * `frame_error` (1-cycle pulse on bad stop interval)

* **Framing**

  * Idle `1` → Start `0` → `DATA_WIDTH` data bits → Stop `1`

---

### **Observed Issues in the RTL**

1. **Inter-bit Sampling Cadence Bug (Wrong `prescale_reg` reload)**

   * **What should happen:** After confirming the start bit at ~½-bit delay, the sampler must reload `prescale_reg` each time to produce **uniform, one-bit-period** spacing between all subsequent sampling instants, so that each sample lands near the **center of its bit cell**.
   * **What the RTL does:** The start confirmation path is fine, but the **subsequent per-bit reload uses a value that is 2 clocks too small**, advancing every data/stop sample by a fixed amount relative to the true bit center.
   * **Quantifying the error:** The sampling point is shifted **earlier by 2 clock cycles** on every bit. The fractional timing error per bit is:

     * `prescale=1` → bit period `8` cycles → **25% UI early** (`2/8`)
     * `prescale=4` → bit period `32` cycles → **6.25% UI early** (`2/32`)
     * `prescale=12` → bit period `96` cycles → **~2.08% UI early** (`2/96`)
   * **Impact:** Early sampling increases susceptibility to edge jitter and metastability, leading to **consistent data errors** (especially at low `prescale`, i.e., higher baud). Stop-bit validation may also intermittently fail when noise or skew is present, sporadically asserting `frame_error`.

2. **Bit Reconstruction Order Bug**

   * **What should happen:** Each sampled data bit must be accumulated so that the byte presented on `m_axis_tdata` follows the UART data format’s **intended bit ordering**.
   * **What the RTL does:** The shift direction/orientation in the data assembly reverses the effective bit order, yielding **bit-reversed bytes** on output.
   * **Impact:** RX delivers bytes that are a mirror of what was sent; loopback and directed RX tests report deterministic mismatches even with ideal waveforms.

> AXI handshake behavior (sticky `m_axis_tvalid` until `m_axis_tready`) and single-cycle pulsing for `overrun_error`/`frame_error` otherwise match the intended contract and should be preserved.

---

### **Failing Test Cases**

1. **RX Test 1 (walk pattern)**

   * **Expected:** Exact match of the driven sequence on `m_axis_tdata`.
   * **Observed:** Mismatches across all elements due to early sampling and/or reversed reconstruction.

2. **RX Test 2 (walk-2 pattern)**

   * **Expected:** Exact match with no errors.
   * **Observed:** Systematic mismatches; sensitivity increases as `prescale` decreases.

---

### **Expected Behavior (post-fix)**

* Sampling after start confirmation follows a **stable, uniform one-bit cadence** so that each data/stop sample occurs **near the bit center** across the frame.
* The reconstructed byte on `m_axis_tdata` reflects the **proper UART data-bit orientation**.
* The stop interval is checked against the idle level; violations assert **`frame_error`** for one cycle.
* **Back-pressure semantics** remain unchanged: `m_axis_tvalid` holds until `m_axis_tready`; completing another byte while one is pending generates a **single-cycle `overrun_error`** without corrupting the held data.
