Debug steps for uart_tx bug fixing

---

## 1) Pre-flight: Know the spec you’re trying to meet

**UART 8N1 framing**

* Idle line = `1`
* Start bit = `0` for 1 bit time
* **Data bits = 8, LSB first**
* Stop bit = `1` for 1 bit time

**Bit timing**

* Bit period in clock cycles: `T_bit = prescale << 3`
* TX accepts **one beat** only when idle (`s_axis_tready=1`).

Keep this mental picture handy while you read waveforms and code.

---

## 2) Reproduce the failure (fast)

Use the simple Verilog TX testbench we prepared. Pick a **non-palindromic** byte to make bit-order mistakes obvious (e.g., `8'h96`, not `8'hA5`).

Expected on-wire sequence after the start bit for `0x96 (1001_0110)`:

* **LSB-first** sequence: `0,1,1,0,1,0,0,1`
  If you see `1,0,0,1,0,1,1,0`, you’re transmitting **MSB-first**.

Also check the **stop** interval: line must be **high** for exactly `T_bit`.

---

## 3) Inspect the waveform

Open the VCD in your viewer and **mark these points**:

1. **Start**: detect falling edge (start bit), line should stay low for `T_bit`.
2. **Bit centers**: every `T_bit` thereafter, sample the value of `txd`.
3. **Data bit order**: compare observed 8 samples with the expected LSB-first sequence.
4. **Stop**: the 10th “interval” (after 8 data bits) must be **high** for one `T_bit`.

**What you’ll likely see (buggy design):**

* Data bits appear **reversed** (MSB-first).
* Stop interval is **low** instead of high.

---

## 4) Code audit: find exactly where it goes wrong

Open `uart_tx.v` and find the **data phase** and **stop phase**:

* **Data phase (when `bit_cnt > 1`)**
  You should find something like:

  ```verilog
  txd_reg      <= data_reg[DATA_WIDTH];
  data_reg     <= {data_reg[DATA_WIDTH-1:0], 1'b0};
  ```

  That drives the **MSB** and shifts **left** → **MSB-first** (wrong).

* **Stop phase (when `bit_cnt == 1`)**
  You may see:

  ```verilog
  txd_reg <= 0;
  ```

  That drives stop as **low** → **framing error** (wrong).

Everything else (prescale reload, ready-when-idle, busy) is otherwise fine in your provided RTL.

---

## 5) Fix strategy (reasoning, not just code)

* **LSB-first** transmitters either:

  * Shift **right** and drive `txd` from the **LSB**, or
  * Use a single concatenation that shifts the entire `{data_reg, txd_reg}` right by one each bit time, so the next `txd` value is the previous LSB.

* **Stop bit** must be **high** for exactly one bit period.

Keep `prescale_reg` reloads consistent to maintain an even cadence (the TX path already uses `(prescale<<3)-1` for start/data and `(prescale<<3)` preload before releasing to idle).

---

## 6) Minimal patch (what to change)

### Data phase (serialize LSB-first)

Replace MSB-drive + left shift with a right-shift pattern that naturally feeds `txd`:

```verilog
// old (wrong): MSB-first
// txd_reg      <= data_reg[DATA_WIDTH];
// data_reg     <= {data_reg[DATA_WIDTH-1:0], 1'b0};

// new (LSB-first): one-step shift into txd
{data_reg, txd_reg} <= {1'b0, data_reg};
```

This simple concatenation means:

* Next `txd_reg` = previous `data_reg[0]` (LSB) ✅
* `data_reg` shifts right (zero-filled) ✅

### Stop phase (drive high for one bit)

```verilog
// old (wrong): txd_reg <= 0;
txd_reg <= 1;
```

> Leave the **prescale_reg** reloads and `bit_cnt` updates as they are (they already match `T_bit` requirements in your fixed RTL). Do not alter the ready-when-idle handshake.

---

## 7) Validate the fix

1. **TX only**: Run the sniffer TB.

   * Start = low for `T_bit`.
   * 8 samples match LSB-first.
   * Stop = high for `T_bit`.

2. **Corner checks**

   * Back-to-back frames: keep `s_axis_tvalid` asserted; ensure `tready` goes high only when idle.
   * Random data including `8'h00`, `8'hFF`, and non-palindromes (`8'h96`, `8'h3C`) to catch ordering mistakes.

---
