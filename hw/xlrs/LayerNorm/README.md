# 🔢 LayerNorm — Hardware Accelerator (RTL Architecture)

## 📘 Overview

This directory implements a modular hardware accelerator for the **AILayerNorm** algorithm (SOLE paper). By offloading the statistical calculations and affine transformation to dedicated RTL, the host CPU experiences a large latency reduction over pure-software execution.

The design is written in **SystemVerilog**, targets a **MAX 10 FPGA** (10M50DAF484C7G), and is synthesized with **Quartus Prime 24.1**. It implements a sequential four-stage Finite State Machine (FSM) pipeline to compute the mean, variance, inverse standard deviation, and final per-channel normalization.

---

## 🧱 Architecture

```text
LayerNorm.sv (top-level FSM)
 ├── zp.sv          // Stage 1: extracts zero-point and quantization params
 ├── ex_ex2.sv      // Stage 2: accumulates E[x] (sum) and E[x²] (sum of squares)
 ├── PreProcess.sv  // Stage 3: computes mean (mu) and inverse std deviation (inv_std)
 └── Affine.sv      // Stage 4: y = gamma * ((x - mu) * inv_std) + beta
```

```text
IDLE ──(start)──► ZP ──(done)──► EX_EX2 ──(done)──► PREPROCESS ──(done)──► AFFINE ──(done)──► DONE
  ▲                                                                                               │
  └───────────────────────────────────────────────────────────────────────────────────────────────┘
                                                    (layernorm_done pulse → IDLE, next vector)
```

Each stage sees its `start` signal asserted while the top FSM is in the corresponding state, and asserts `done` when finished — the top FSM transitions immediately on `done`.

---

## 🧩 Module Descriptions

### 🔹 `LayerNorm.sv` *(Top-Level Module)*
**Role**: Orchestrates the full LayerNorm pipeline.

**Responsibilities**:
- Exposes 6 `host_regs` for configuration and start/done signaling (see [Register Map](#-memory-interface--register-map) below).
- Contains a combinational mux that routes the shared XMEM read bus to whichever stage is currently active; only the `Affine` stage drives the write bus.
- Manages the top-level FSM state.

```systemverilog
// Read bus: routed by top FSM state
always_comb begin
  case (state)
    ZP:         mem_intf_read ← zp_mem_*
    EX_EX2:     mem_intf_read ← ex_mem_*
    PREPROCESS: mem_intf_read ← pp_mem_*
    AFFINE:     mem_intf_read ← af_rd_mem_*
  endcase
end

// Write bus: Affine stage only
if (state == AFFINE)  mem_intf_write ← af_wr_mem_*
```

---

### 🔹 `zp.sv` (`zp_stage`)
**Role**: Fetches the quantization zero-points needed by later stages.

**Responsibilities**: Reads `global_zp`, `gamma_zp`, and `beta_zp` from the shared configuration struct in XMEM.

---

### 🔹 `ex_ex2.sv` (`ex_ex2_stage`)
**Role**: Scans all input channels to accumulate statistical moments.

**Responsibilities**:
- Accumulates the sum of inputs, `E[x]`.
- Accumulates the sum of squares, `E[x²]`, via SOLE's dynamic-compression scheme (8-bit → 4-bit code → 16-entry square LUT).
- Determines the minimum per-channel scale exponent, `min_alpha`, used for relative-shift PTF encoding.

**Processing model**: channel-sequential (one channel per cycle) — see [Chunk-Sequential Processing](#-channel-sequential-processing) below.

---

### 🔹 `PreProcess.sv` (`preprocess_stage`)
**Role**: Resolves the final mean and inverse standard deviation.

**Responsibilities**: Computes `mu` (mean) from `E[x]`, and `inv_std` from `E[x]`/`E[x²]` via a LUT lookup.

**Optimizations**:
- 🧮 **Reciprocal multiplication**: eliminates division hardware entirely — both fixed-constant divisions (`/384`, `/24`) are implemented as a multiply by a precomputed constant followed by a bit-shift.
- ⚡ **LUT for `1/√σ²`**: a 256-entry, 16-bit lookup table (supplied by the host in shared memory) replaces an iterative inverse-square-root circuit.
- 🧷 **Pipeline register (`mu_comb_reg`)**: added during timing closure to break the stage's long combinational path into two shorter segments.

FSM: `IDLE → COMP_MU → RD_LUT → DONE_ST`

---

### 🔹 `Affine.sv` (`affine_stage`)
**Role**: Computes and writes the final normalized output.

$$
y_i = \gamma_i \cdot \left((x_i-\mu)\cdot \text{inv\_std}\right)+\beta_i
$$

**Responsibilities**:
- Re-reads the input vector (a second pass, independent of `ex_ex2`'s pass).
- Applies the affine transform in 64-bit signed arithmetic to prevent overflow.
- Rounds (arithmetic right-shift `>>> 14`), clamps to `[-128, 127]`, and writes the result to `output_addr`.

**Processing model**: channels are processed in **chunks of 32** (one 32-byte XMEM line) — 384 / 32 = 12 chunks per vector. Each chunk requires four reads (α, γ, β, input) and one write. FSM per chunk: `RD_ALPHA → RD_GAMMA → RD_BETA → RD_INPUT → PROCESS → WR_OUTPUT`.

**Optimization — pipeline registers**: the `PROCESS` step contains a 4-stage internal pipeline (added during timing closure) to break up a long serial multiply chain (`xm × inv_std` feeding `xm_norm × gamma`), at a cost of +48 cycles/vector.

Throughput: **612 clock cycles per vector**.

---

## ⚙️ Channel-Sequential Processing

An initial architecture processed **32 channels per cycle** in parallel, matching the SOLE paper's own hardware evaluation. On synthesis, this proved unsynthesizable on the target FPGA: address-dependent random access into 384-entry per-vector buffers (`alpha_buf`, `gamma_buf`, etc.) prevented block-RAM inference, forcing the synthesis tool to replicate a 384:1 multiplexer 32 times — **~450,742 Logic Elements** against a budget of ~50,000.

Re-architecting around **channel-sequential** processing (one channel per cycle, through small fixed-size line buffers instead of full 384-entry register arrays) reduced resource usage by **×77**, to **5,878 LEs**, while increasing per-vector hardware compute cycles from ~200 to ~1,000 — a cost of under 0.1% of total system latency (see the root [README](../../../README.md) for the full speedup analysis).

---

## 🧮 Pipeline Summary (Top FSM)

| State | Module | Function |
|---|---|---|
| 1️⃣ `IDLE` | top FSM | Waits for `start` from host |
| 2️⃣ `ZP` | `zp_stage` | Fetches zero-points and quantization params |
| 3️⃣ `EX_EX2` | `ex_ex2_stage` | Accumulates E[x], E[x²]; finds `min_alpha` |
| 4️⃣ `PREPROCESS` | `preprocess_stage` | Computes `mu` and `inv_std` |
| 5️⃣ `AFFINE` | `affine_stage` | Normalizes, transforms, and writes output |
| 6️⃣ `DONE` | top FSM | Asserts done to host (sticky until next `START`) |

---

## 🗺️ Memory Interface & Register Map

### Host register map (6 registers, 32-bit each)

| Index | Name | Direction | Description |
|---|---|---|---|
| 0 | `SOLE_SHARED_ADDR_REG` | SW→HW | Base address of the shared config struct in XMEM |
| 1 | `SOLE_INPUT_ADDR_REG` | SW→HW | Base address of the current input vector |
| 2 | `SOLE_OUTPUT_ADDR_REG` | SW→HW | Base address of the output vector |
| 3 | `SOLE_NUM_CH_REG` | SW→HW | Number of channels (384) |
| 4 | `SOLE_START_REG` | SW→HW | Write 1 to start one vector |
| 5 | `SOLE_DONE_REG` | HW→SW | Reads 1 when done (sticky until next `START`) |

---

## 📈 Synthesis Results

Device: **MAX 10 — 10M50DAF484C7G**
Tool: **Quartus Prime 24.1std** (`qsyn_xlr LayerNorm -all`)

| Metric | Value | Notes |
|---|---|---|
| Logic Elements (synthesis / map) | **5,878** | Reported by `qsyn_xlr`; mid-flow synthesis result |
| Logic Elements (post-fitter / P&R) | **4,769** | After Quartus Fitter LUT/register merging |
| Dedicated registers | 2,819 (map) / 2,723 (fit) | |
| Embedded Multiplier 9-bit elements | 34 | |
| Memory bits | 96 | |
| Max Frequency | **54.22 MHz** | From STA: slack = −17.44 ns at a 1 ns constraint |

> The two Logic Element counts refer to different stages of the Quartus flow. `qsyn_xlr` (the course tool) reports from `map.rpt` (synthesis); the Fitter further reduces this to 4,769 by merging logic during Place & Route. Both are correct; both reports are in `qsyn_output_files/`.

### 🕓 Optimization History (Timing Closure Journey)

| Step | LEs | F_max |
|---|---|---|
| Initial parallel architecture (32 channels/cycle) | 450,742 | 6.87 MHz |
| Final channel-sequential architecture, after a multi-round timing-closure process | 5,878 | **54.22 MHz** |

Re-architecting from the parallel to the channel-sequential datapath, combined with pipeline registers added at multiple points during timing closure (including `mu_comb_reg` in `PreProcess.sv`), brought the design from 6.87 MHz to 54.22 MHz (×7.9) at the same 5,878 LE count.

---

## 🧪 Standalone Testbenches

Each stage has its own standalone testbench that runs independently of the full system. All testbenches run 15 representative vectors and require bit-exact output against a golden C reference.

| Testbench | Module under test | Data dependency |
|---|---|---|
| `tb_zp.sv` | `zp.sv` | Inline / embedded |
| `tb_ex_ex2.sv` | `ex_ex2.sv` | Inline / embedded |
| `tb_preprocess.sv` | `PreProcess.sv` | `/tmp/tb_pp_lut.hex` (inv_sqrt LUT) |
| `tb_affine.sv` | `Affine.sv` | `/tmp/tb_af_*.hex`, `/tmp/tb_vec*.hex`, `/tmp/affine_golden/*.hex` |

### ▶️ Run command (from `hw/xlrs/LayerNorm/`)

```bash
# Example: PreProcess testbench
xrun -sv -timescale 1ns/1ps \
  +incdir+$K5_ENV/src/common \
  $K5_XBOX_ENV/hw/xbox/xbox_def_pkg.sv \
  PreProcess.sv tb_preprocess.sv \
  -top tb_preprocess \
  -nowarn DLCVAR:NCEXDEP:DSEM2009:DSEMEL:MTDYNUSE:CUMSTS \
  -UNBUFFERED

# Replace PreProcess.sv / tb_preprocess.sv / -top tb_preprocess
# with the corresponding filenames for other stages.
```

> `tb_affine.sv` loads its test data from `/tmp/*.hex` files that must be pre-generated by a separate Python script (not included in this repository). When absent, the testbench still compiles and runs but reports `xx` (unknown) for all data — in that case, PASS reflects only timing correctness, not data correctness.

### 📊 Sample Testbench Output

Captured from `tb_preprocess.sv`. All 15 vectors pass with **delta = 0** (bit-exact), confirming the `mu_comb_reg` pipeline register does not alter computed values:

```text
=== PREPROCESS MULTI-VECTOR TESTBENCH ===
  Vec | mu_golden   mu_RTL     delta cmp || is_golden is_RTL delta cmp || result
  ----|--------------------------------------||----------------------------||-------
    0 | 0x00000000 | 0x00000000 |    0 | OK || 0x0071 | 0x0071 |   0 | OK || PASS
    1 | 0xfffffff6 | 0xfffffff6 |    0 | OK || 0x008b | 0x008b |   0 | OK || PASS
   ...
  196 | 0xffffffff | 0xffffffff |    0 | OK || 0x0086 | 0x0086 |   0 | OK || PASS
  ----|--------------------------------------||----------------------------||-------
  Passed: 15 / 15
  >>> ALL PASS <<<
```

Columns: `mu` = mean (signed 32-bit), `is` = `inv_std` (unsigned 16-bit, LUT output). `delta` = RTL − golden; 0 on every row confirms bit-exact match.

---

## 🛠️ Usage

Refer to the [root README](../../../README.md) for how to run the full simulation, and to the [Software README](../../../sw/apps/LayerNorm/README.md) for the software driver and validation methodology.
