# AXI4-Stream UART (TX/RX/Top) — Specification Document

## Introduction

This document specifies a minimal **AXI4-Stream UART** consisting of three RTL blocks:

* **`uart_tx`** — AXI-Stream to UART transmitter
* **`uart_rx`** — UART to AXI-Stream receiver
* **`uart`** — Top-level wrapper that instantiates `uart_tx` and `uart_rx`

The design implements **8N1 framing** (1 start bit, 8 data bits, 1 stop bit, no parity) with a programmable baud rate via a **prescaler**. The AXI4-Stream side is **one byte per beat** (no `tkeep`/`tlast`) with standard `tvalid/tready` back-pressure. The UART line idles **high**.

---

## UART Framing & Timing

### Line Format

* **Idle:** `1`
* **Start bit:** `0` for one bit time
* **Data bits:** `DATA_WIDTH` bits, **LSB first**
* **Stop bit:** `1` for one bit time

### Bit Timing (Prescaler)

* **Bit period (in clk cycles):**
  `T_bit = prescale << 3 = prescale * 8`
* **Suggested baud calculation:**
  `prescale = f_clk / (baud * 8)` (rounded to nearest integer)

### Receive Sampling (8× oversample)

* Detect start edge (`rxd == 0`), then wait roughly **½ bit** to re-sample near the bit center:
  `prescale_reg <= (prescale << 2) - 2`
* Subsequent samples occur every bit period:
  `prescale_reg <= (prescale << 3) - 1` (≈ `8*prescale - 1`)

---

## Module: `uart_tx` — AXI-Stream to UART Transmitter

### Interface: uart_tx

```verilog
module uart_tx #(
  parameter DATA_WIDTH = 8
)(
  input  wire                  clk,
  input  wire                  rst,
  // AXI4-Stream input (1 byte/beat)
  input  wire [DATA_WIDTH-1:0] s_axis_tdata,
  input  wire                  s_axis_tvalid,
  output wire                  s_axis_tready,
  // UART line
  output wire                  txd,
  // Status
  output wire                  busy,
  // Configuration
  input  wire [15:0]           prescale
);
```

### Port Description: uart_tx

| Port            | Dir | Description                                                      |
| --------------- | --- | ---------------------------------------------------------------- |
| `clk`           | in  | System clock.                                                    |
| `rst`           | in  | Synchronous active-high reset.                                   |
| `s_axis_tdata`  | in  | Byte to transmit (LSB sent first).                               |
| `s_axis_tvalid` | in  | Valid qualifier for `s_axis_tdata`.                              |
| `s_axis_tready` | out | TX ready to accept a byte **only when idle** (one-cycle accept). |
| `txd`           | out | UART transmit line (idles high).                                 |
| `busy`          | out | High while a frame is being transmitted.                         |
| `prescale`      | in  | Bit time control (see **Bit Timing**).                           |

### Behavior

1. **Ready/Handshake**

   * `s_axis_tready = 1` only when **idle** (`bit_cnt == 0` and timer idle).
   * On `s_axis_tvalid && s_axis_tready`, TX latches the byte and immediately starts the start bit.
   * `s_axis_tready` is then deasserted until the entire frame completes.

2. **Framing**

   * **Start bit:** drive `txd = 0` for `T_bit` cycles.
   * **Data bits:** shift out **LSB first**; one bit per `T_bit`.
   * **Stop bit:** drive `txd = 1` for `T_bit` cycles.
   * `busy` is asserted during the whole frame.

3. **Counters**

   * `prescale_reg` (≈19b): down-counter for intra-bit timing.
   * `bit_cnt` (4b): counts remaining bits in the frame (`DATA_WIDTH + 1` for data+stop).

### Latency & Throughput

| Event                             | Latency                           |
| --------------------------------- | --------------------------------- |
| Accept byte after idle `tready=1` | 1 cycle handshake                 |
| Start bit drive after accept      | Same cycle/next (registered)      |
| Byte transmit time                | `(DATA_WIDTH + 2) * T_bit` cycles |

* **Throughput:** One byte per `(DATA_WIDTH+2)` bit times (no streaming overlap; single-entry buffer).

---

## Module: `uart_rx` — UART to AXI-Stream Receiver

### Interface: uart_rx

```verilog
module uart_rx #(
  parameter DATA_WIDTH = 8
)(
  input  wire                  clk,
  input  wire                  rst,
  // AXI4-Stream output (1 byte/beat)
  output wire [DATA_WIDTH-1:0] m_axis_tdata,
  output wire                  m_axis_tvalid,
  input  wire                  m_axis_tready,
  // UART line
  input  wire                  rxd,
  // Status
  output wire                  busy,
  output wire                  overrun_error,
  output wire                  frame_error,
  // Configuration
  input  wire [15:0]           prescale
);
```

### Port Description

| Port            | Dir | Description                                                                                                        |
| --------------- | --- | ------------------------------------------------------------------------------------------------------------------ |
| `clk`           | in  | System clock.                                                                                                      |
| `rst`           | in  | Synchronous active-high reset.                                                                                     |
| `m_axis_tdata`  | out | Received byte (stable while `m_axis_tvalid=1`).                                                                    |
| `m_axis_tvalid` | out | Asserted when a byte is ready; **held** until `m_axis_tready`.                                                     |
| `m_axis_tready` | in  | Downstream ready for one-beat transfer.                                                                            |
| `rxd`           | in  | UART receive line (idles high).                                                                                    |
| `busy`          | out | High while the receiver is actively sampling a frame.                                                              |
| `overrun_error` | out | **One-cycle pulse** if a new byte completes while the previous has not been accepted (`m_axis_tvalid` still high). |
| `frame_error`   | out | **One-cycle pulse** on stop-bit error (expected `1`, sampled `0`).                                                 |
| `prescale`      | in  | Bit time control (see **Bit Timing**).                                                                             |

### Receive Procedure

1. **Idle & Start Detection**

   * While idle (`busy=0`), watch for `rxd=0`.
   * On low, preload `prescale_reg <= (prescale<<2)-2` (~½ bit) and set `bit_cnt <= DATA_WIDTH + 2` (start confirm + data + stop), `busy<=1`.

2. **Start Confirmation**

   * After the ½-bit delay, if line is still low, proceed; otherwise abort (spurious glitch).

3. **Data Bit Sampling**

   * Every `T_bit` cycles, sample the line near bit center.
   * **LSB-first reconstruction:**
     `data_reg <= {rxd_sample, data_reg[DATA_WIDTH-1:1]}`
     After `DATA_WIDTH` samples, `data_reg` holds the byte in correct order.

4. **Stop Bit Check & AXIS Output**

   * On stop sample: if `rxd==1`, assert `m_axis_tvalid` and drive `m_axis_tdata <= data_reg`.
   * If `m_axis_tvalid` was already high (previous byte unconsumed), assert **`overrun_error`** for one cycle.
   * If `rxd==0` at stop, assert **`frame_error`** for one cycle and drop the byte.

5. **AXIS Handshake**

   * `m_axis_tvalid` remains **asserted** until `m_axis_tready` is seen; then it clears.

### Latency & Back-pressure

| Event                           | Behavior                                                                              |
| ------------------------------- | ------------------------------------------------------------------------------------- |
| First sample after start detect | ~½ bit after falling edge                                                             |
| Byte availability (`tvalid=1`)  | Immediately after stop check                                                          |
| Back-pressure                   | Byte is **held** until accepted; next completed byte during hold triggers **overrun** |

---

## Top-Level: `uart`

### Interface

```verilog
module uart #(
  parameter DATA_WIDTH = 8
)(
  input  wire                  clk,
  input  wire                  rst,
  // AXI4-Stream in (TX)
  input  wire [DATA_WIDTH-1:0] s_axis_tdata,
  input  wire                  s_axis_tvalid,
  output wire                  s_axis_tready,
  // AXI4-Stream out (RX)
  output wire [DATA_WIDTH-1:0] m_axis_tdata,
  output wire                  m_axis_tvalid,
  input  wire                  m_axis_tready,
  // UART pins
  input  wire                  rxd,
  output wire                  txd,
  // Status
  output wire                  tx_busy,
  output wire                  rx_busy,
  output wire                  rx_overrun_error,
  output wire                  rx_frame_error,
  // Configuration
  input  wire [15:0]           prescale
);
```

* Instantiates `uart_tx` and `uart_rx` and wires `prescale` to both.
* Provides consolidated status (`tx_busy`, `rx_busy`, `rx_overrun_error`, `rx_frame_error`).

---

## Internal Architecture

### `uart_tx`

* **Registers**

  * `data_reg [DATA_WIDTH:0]`: shift register (includes stop bit pre-load).
  * `prescale_reg [18:0]`: per-bit down-counter.
  * `bit_cnt [3:0]`: counts remaining data/stop bits.
  * `txd_reg`, `busy_reg`, `s_axis_tready_reg`.
* **Operation**

  * Idle → accept beat → start bit → data bits (LSB first) → stop bit → idle.

### `uart_rx`

* **Registers**

  * `data_reg [DATA_WIDTH-1:0]`: reconstructed byte.
  * `prescale_reg [18:0]`: sampling timer.
  * `bit_cnt [3:0]`: counts start/data/stop phases.
  * `m_axis_tdata_reg`, `m_axis_tvalid_reg`, `busy_reg`.
  * `overrun_error_reg`, `frame_error_reg`.
  * `rxd_reg`: 1-FF input synchronizer (single stage).
* **Operation**

  * Idle detect → mid-start confirm → data sampling at bit centers → stop check → AXIS present/hold.

---

## Reset Behavior

* **Synchronous** active-high reset (`rst`).
* Clears all internal registers, counters, status, and `tvalid/tready` to idle defaults:

  * TX: `txd=1`, `busy=0`, `s_axis_tready=0` (re-asserted when idle after reset releases).
  * RX: `m_axis_tvalid=0`, `busy=0`, errors cleared.

---

## Assumptions & Limits

* **Clocking:** Single synchronous clock domain for AXI and UART sampling logic.
* **Prescale range:** 16-bit input; effective bit timer uses 19 bits.
* **Data width:** Parameter `DATA_WIDTH` (default 8); `bit_cnt` sized for up to 10 bits (8 data + start/stop bookkeeping).
* **Metastability:** RX uses a single-FF input stage; for robust async inputs, a **2-FF synchronizer** is recommended at top-level integration.
* **No parity / multi-stop support** in this version (8N1 only).
* **Buffering:** TX single-entry (accepts when idle). RX has **no FIFO**; overrun flagged if output byte is not consumed before next completes.

---

## Timing Summary

| Item                    | Value/Rule                                                     |
| ----------------------- | -------------------------------------------------------------- |
| Bit time                | `T_bit = prescale * 8` clock cycles                            |
| TX accept window        | Only when idle (`tready=1`)                                    |
| TX frame duration       | `(DATA_WIDTH + 2) * T_bit` cycles                              |
| RX start re-sample      | `(prescale<<2) - 1` cycles after start edge                    |
| RX inter-bit spacing    | `(prescale<<3) - 1` cycles                                     |
| RX `m_axis_tvalid` hold | Until `m_axis_tready`                                          |
| Overrun indication      | 1-cycle pulse on new-byte completion while previous `tvalid=1` |
| Frame error             | 1-cycle pulse on stop bit `0`                                  |

---

## Integration & Configuration Notes

* **Baud programming:** Compute `prescale = f_clk / (baud * 8)`; verify tolerance with your clock and desired baud.
* **Back-pressure:** Ensure downstream consumer asserts `m_axis_tready` frequently enough to avoid `overrun_error`.
* **Clock domain crossing:** If `rxd` originates from another clock domain or an external pad, insert a **2-FF synchronizer** before `uart_rx`.
* **Synthesis:** Modules are Verilog-2001; no vendor primitives required.

---


