# Debug Steps for uart_rx bug fixing

---

## 1) Start from the spec you must satisfy

**UART 8N1 framing**

* Idle = `1`
* Start = `0` (1 bit time)
* **Data = 8 bits, LSB first**
* Stop = `1` (1 bit time)

**Sampling strategy**

* After the falling edge (start detect), wait roughly **½ bit** and confirm start is still low.
* Then sample **once per bit** at the **bit center** using a timer:

  * Bit period in clock cycles: `T_bit = (prescale << 3)`.

**AXI-Stream contract**

* Assert `m_axis_tvalid` when a byte is ready and **hold** until `m_axis_tready`.
* If a new byte finishes while the previous is still pending, **pulse** `overrun_error` for one cycle.

---

## 2) Reproduce the failure (make it obvious)

Use the RX Verilog TB that **bit-bangs `rxd`** with precise bit timing. Drive **non-palindromic** bytes (e.g., `8'h96` → `1001_0110`) so bit-order mistakes are visible.

* Expect **LSB-first** sampled sequence after start: `0,1,1,0,1,0,0,1`.
* If you read `1,0,0,1,0,1,1,0`, the RX is **reversing** bit order.
* At **small prescale** (e.g., `prescale=1`), if bytes corrupt more often, suspect **early sampling**.

---

## 3) Inspect waveforms (what to mark)

Open the VCD and watch at least these:

* `rxd`, `rxd_reg`
* `prescale_reg`, `bit_cnt`
* A derived **sample strobe**: `sample = (prescale_reg==0) && (bit_cnt>0)`
* `data_reg`, `m_axis_tdata`, `m_axis_tvalid`, `frame_error`, `overrun_error`

**Checks**

1. **½-bit start confirm**: From start edge to first sample ~ `T_bit/2`.
2. **Uniform cadence**: Subsequent `sample` pulses spaced exactly `T_bit` apart.
3. **Centering**: Each `sample` occurs **near the middle** of each bit cell.
4. **Reconstruction**: After 8 samples, `m_axis_tdata` must equal the driven byte.
5. **Stop check**: The sample taken for stop should see `1`; otherwise `frame_error` pulses.

**What you’ll likely see (buggy design):**

* `sample` pulses come **2 clocks early** each bit (timer reload too small).
* `data_reg` shifts in a way that **reverses** bit order.

---

## 4) Code audit: find the exact problems

Open `uart_rx.v` and look at two places:

### A) Inter-bit timer reload (inside receive state)

You’ll see a reload like:

```verilog
prescale_reg <= (prescale << 3) - 3; // <— too small by 2 clocks
```

That makes every sampling point **early by 2 cycles**. The fractional error per bit is `2 / (prescale<<3)` (e.g., 25% UI at `prescale=1`, 6.25% at `prescale=4`), which is enough to miss the bit center and corrupt data.

**Start confirm preload** (`(prescale<<2)-2`) is okay; the bug is in the **per-bit** reload.

### B) Bit reconstruction orientation (data phase)

You’ll see something like:

```verilog
data_reg <= {data_reg[DATA_WIDTH-2:0], rxd_reg}; // shift left, append to LSB
```

That accumulates **MSB-first** (reverses the final byte). For UART, you must reconstruct **LSB-first**.

---

## 5) Fix strategy (reasoning before code)

* **Sampling cadence** must be **uniform per bit**: after each sample, reload the timer so the **next** sample lands one full `T_bit` later (near the center). That means reloading to **`T_bit - 1`** for a down-counter that samples when it hits zero.
* **Reconstruction order** must match UART’s **LSB-first** bit ordering. Shift so the **newly sampled bit** becomes the **MSB of `data_reg`** only after you’ve shifted right, or equivalently, **prepend** the sampled bit and **shift right**.

---

## 6) Minimal patches (what to change)

> Keep your AXI handshake and error flag pulse behavior exactly as is.

### A) Timer reload for data/stop sampling

Use a per-bit reload that equals **one bit period**:

```verilog
// Per-bit cadence (data & stop phases):
prescale_reg <= (prescale << 3) - 1;
```

Apply this in the data-bit path (and the “countdown through stop” path where appropriate). The **start confirm** line `(prescale<<2)-2` remains unchanged.

### B) LSB-first reconstruction

Replace the left-shift/append with a **right-shift/prepend**:

```verilog
// LSB-first accumulation
data_reg <= {rxd_reg, data_reg[DATA_WIDTH-1:1]};
```

This makes the next `data_reg[0]` be the **oldest** captured bit (LSB first overall), yielding the correct byte.

---

## 7) Validate the fix

1. **RX TB** (bit-banged `rxd`)

   * Confirm `sample` pulses are spaced exactly `T_bit` apart.
   * For `0x96`, captured sequence matches LSB-first ordering.
   * `m_axis_tvalid` asserts once per byte and holds until `m_axis_tready`.

2. **Stress**

   * Try small `prescale` (1–4) and larger values (8–16) to ensure stability.
   * Drive corner bytes: `8'h00`, `8'hFF`, `8'h01`, `8'h80`, and non-palindromic values (`8'h96`, `8'h3C`).

---
