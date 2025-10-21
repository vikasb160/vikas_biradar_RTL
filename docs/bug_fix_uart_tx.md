# UART Transmit RTL (`uart_tx`) Bug Fixes

Identify and correct logical bugs in the **UART Transmit RTL (`uart_tx`)** related to **bit ordering** and **stop-bit generation**. The issues corrupt the on-wire UART framing and cause systematic mismatches in the TX self-check and loopback tests.

---

## **Module Overview**

The `uart_tx` module serializes AXI4-Stream bytes into an **8N1 UART** frame with a programmable bit time.

* **Inputs**

  * `clk` — System clock
  * `rst` — Synchronous, active-high reset
  * `s_axis_tdata[DATA_WIDTH-1:0]` — Byte to transmit (one beat)
  * `s_axis_tvalid` — Valid qualifier
  * `prescale[15:0]` — Bit-timer scalar; `T_bit = prescale << 3`

* **Outputs**

  * `s_axis_tready` — High only when TX is idle (one-beat accept)
  * `txd` — UART line (idle high)
  * `busy` — High while a frame is being sent

* **Frame format (8N1)**

  * Idle = `1` → Start = `0` (1 bit) → 8 data bits (serialized per spec) → Stop = `1` (1 bit)

---

### **Observed Issues in the RTL**

1. **Bit Ordering Violation**

   * **Expected:** During the data phase, the serializer must emit bits in the order mandated by the UART specification.
   * **Actual:** The current implementation emits the opposite ordering, leading to consistent byte reversals on the wire.
   * **Impact:** The TX sniffer and loopback decoder report deterministic data mismatches for all payloads.

2. **Stop-Bit Level Violation**

   * **Expected:** The stop interval must drive the line to the defined idle level for exactly one bit period.
   * **Actual:** The stop interval is driven to the wrong level.
   * **Impact:** Receivers may flag a **framing error** and/or drop bytes, compounding data mismatches.

> Timing (`prescale_reg` loads) and the ready-when-idle handshake policy are otherwise acceptable and should remain intact.

---

### **Failing Test Cases**

1. **TX Test 1 (walk pattern)**

   * **Expected:** Exact byte match at the sniffer.
   * **Observed:** All bytes mismatch due to incorrect on-wire bit ordering and/or stop interval level.

2. **TX Test 2 (walk-2 pattern)**

   * **Expected:** Exact byte match.
   * **Observed:** Same systematic mismatches as Test 1.

---

### **Expected Behavior (post-fix)**

* The serialized frame on `txd` **fully complies with 8N1 UART requirements**, including:

  * Correct start interval and stop interval levels.
  * Data-bit serialization order consistent with the UART data format specification.
  * Stable per-bit timing equal to one bit period (`T_bit`) for each interval.
* AXI4-Stream handshake remains **ready-when-idle** with one-beat acceptance per frame.
