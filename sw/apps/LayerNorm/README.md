# 💻 LayerNorm — Software Application

## 📘 Overview

This directory contains the software application that runs on the K5 RISC-V core. It implements the **SOLE** Layer Normalization algorithm (AILayerNorm) in two selectable modes:
- **SW-only** (`layernorm_nox`): a pure RISC-V software reference implementation
- **HW-accelerated** (`layernorm_xlr`): drives the RTL accelerator via memory-mapped registers

It is also responsible for programming the host memory-mapped registers, initializing shared memory, and validating the hardware output against the software reference.

### 🔍 Our Implementation

```text
┌──────────────┐    ┌─────────────┐    ┌────────────┐    ┌──────────────┐
│  Initialize  │    │  Configure  │    │ Wait for   │    │  Validate    │
│  Memory      │───►│  Registers  │───►│ Hardware   │───►│  Results     │
│ (In/Out/Shr) │    │ (Reg 0-4)   │    │ (Poll Reg5)│    │ (vs. Golden) │
└──────────────┘    └─────────────┘    └────────────┘    └──────────────┘
```

**Key Responsibilities:**
- 🧠 Generating quantized test inputs and the floating-point golden reference
- 🗺️ Allocating and formatting the shared memory regions consumed by the RTL
- ⏱️ Performance benchmarking (cycle-accurate breakdown) of both execution paths
- ✅ Automated accuracy evaluation (MAE%) against the golden reference

---

## 🗂️ Files

| File | Purpose |
|---|---|
| `sole_ref.c` | Main application: SW reference (`layernorm_nox`), HW accelerator driver (`layernorm_xlr`), cycle-count breakdown |
| `gen_sole_test.py` | Generates `sole_test_in.txt` and `sole_test_config.txt` from quantized model data |
| `check_sole.py` | Reads `sole_test_out.txt`, dequantizes, computes per-vector MAE% against the PyTorch golden reference |
| `build/` | Pre-built RISC-V binaries in loadmem format (`LayerNorm.elf`, `instr_loadmem.txt`, `data_loadmem.txt`) — auto-generated on run |

---

## 🔌 Register Interface (`layernorm_xlr`)

Six memory-mapped 32-bit registers, at `XBOX_REGS_BASE_ADDR`:

| Reg | Macro | Direction | Description |
|---|---|---|---|
| 0 | `SOLE_SHARED_ADDR_REG` | Write | Address of the shared configuration struct |
| 1 | `SOLE_INPUT_ADDR_REG` | Write | Address of the input vector |
| 2 | `SOLE_OUTPUT_ADDR_REG` | Write | Address of the output vector |
| 3 | `SOLE_NUM_CH_REG` | Write | Number of channels (384) |
| 4 | `SOLE_START_REG` | Write 1 | Starts computation for one vector |
| 5 | `SOLE_DONE_REG` | Read | Reads 1 when done (sticky bit, cleared on next `START`) |

### 🔄 Execution Flow (`layernorm_xlr`)
1. **Memory allocation** — buffers for input, output, and shared parameters are placed in XMEM.
2. **Register programming** — addresses and channel count written to Regs 0–3.
3. **Trigger** — write `1` to Reg 4 (`SOLE_START_REG`).
4. **Polling** — poll Reg 5 (`SOLE_DONE_REG`) until the hardware sets it to `1`.
5. **Validation** — read the output memory and compare against the software reference / golden data.

---

## 🧠 `sole_ref.c` — Application Structure

### Key constants (from source)

```c
#define MAX_CHANNELS   384   // Fixed number of channels per vector
#define MAX_VECTORS    197   // Number of test vectors in the dataset
#define BATCH_VECTORS   80   // Vectors loaded into XMEM per DMA batch
```

### `SoleShared` struct layout

The shared configuration blob is packed into XMEM at address `0x40000000`. Its layout (1684 bytes total) must match exactly between `sole_ref.c` and `gen_sole_test.py`:

| Offset | Size | Field | Type |
|---|---|---|---|
| 0 | 4 B | `num_vectors` | int32 |
| 4 | 4 B | `num_channels` | int32 |
| 8 | 4 B | `global_zp` | int32 |
| 12 | 4 B | `gamma_zp` | int32 |
| 16 | 4 B | `beta_zp` | int32 |
| 20 | 384 B | `alpha_factors[384]` | int8 × 384 |
| 404 | 384 B | `gamma_q[384]` | uint8 × 384 |
| 788 | 384 B | `beta_q[384]` | uint8 × 384 |
| 1172 | 512 B | `inv_sqrt_lut[256]` | uint16 × 256 (little-endian) |
| **1684** | **total** | | |

### SW computation flow (`layernorm_nox`)

1. `find_min_alpha()` — finds the minimum across `alpha_factors[num_channels]`
2. `stage1()` — accumulates `E[x]` and `E[x²]` with per-channel dynamic compression
3. `stage2_improved()` — computes μ, variance, looks up the `inv_sqrt` LUT, applies the per-channel affine transform (γ, β), and clamps the output to int8

This is the exact software-only path mirrored by the RTL pipeline described in the [Hardware README](../../../hw/xlrs/LayerNorm/README.md).

---

## 📦 `gen_sole_test.py` — Test Data Generation

Reads quantized model parameters from `data/quantized_noclip/` and packs them into the binary format expected by `sole_ref.c`.

> **Note:** the `data/` directory is **not included** in this repository. The pre-generated output files (`sole_test_in.txt`, `sole_test_config.txt`) are already present in `sim/t0/` and are ready to use without re-running this script.

### Outputs

| File | Contents |
|---|---|
| `sole_test_in.txt` | Hex dump: 1684-byte `SoleShared` blob + 197×384 bytes of input vectors |
| `sole_test_config.txt` | Scaling parameters + PyTorch golden reference values, per vector |

### Input data sources (relative to this directory)

```
data/
├── quantized_noclip/
│   ├── global_params.txt      # num_channels, num_vectors, global scale/zp
│   ├── alpha_factors.txt      # per-channel alpha exponents (int8)
│   ├── gamma_quantized.txt    # γ weights: count, scale, zp, values
│   ├── beta_quantized.txt     # β weights: count, scale, zp, values
│   ├── vectors/vector_NNN.txt # per-vector quantized input (384 values)
│   └── golden_refs/           # PyTorch floating-point reference outputs
└── lut/lut_inv_sqrt.txt       # 256 uint16 entries for 1/√var lookup
```

---

## ✅ `check_sole.py` — Accuracy Evaluation

### Dequantization (Method D)

```
y_real[i] = y_int8[i] * gamma_scale + (beta_q[i] - beta_zp) * (beta_scale - gamma_scale)
```

### MAE% — the official acceptance criterion

```python
def compute_mae_pct(y_float, golden):
    out_range = max(golden) - min(golden)
    mae = sum(abs(y_float[i] - golden[i]) for i in range(len(golden))) / len(golden)
    return mae / out_range * 100.0
```

**MAE%** is range-normalized: it divides the raw mean absolute error by that vector's own output range, expressed as a percentage. **Acceptance threshold: 5%** — a vector passes if its MAE% is below this.

**Two distinct metrics are used on the same underlying error data — do not conflate them:**

| Metric | Formula | Used for |
|---|---|---|
| **MAE%** | `MAE / output_range × 100` | **Official pass/fail criterion** (5% threshold) |
| **raw MAE** | `mean(\|ŷ − y\|)`, not normalized | Error-source decomposition only |

The raw MAE (≈ 2.11%) decomposes as: **82.3%** from integer arithmetic truncation in the `Affine` stage (`>>14` rounding), **14.9%** from quantization + statistics + LUT approximation, **2.8%** from γ/β quantization.

---

## ▶️ Running the Evaluation

### Full simulation (two terminals, from `sim/`)

```bash
# SW-only mode (pure RISC-V, no HW accelerator):
# Terminal 1:
launch_k5_app LayerNorm
# Terminal 2:
launch_k5_sim LayerNorm

# HW-accelerated mode (RTL accelerator active):
# Terminal 1:
launch_k5_app LayerNorm -ccd1 XON
# Terminal 2 (identical to SW-only):
launch_k5_sim LayerNorm
```

> `XON` is a software-side flag only: it controls whether `sole_ref.c` calls `layernorm_xlr()` (HW) or `layernorm_nox()` (SW). The RTL is always compiled into the simulation regardless of mode.

`check_sole.py` is invoked automatically by the application at the end of the run.

### Running `check_sole.py` standalone

```bash
cd sim/t0/
python3 ../../sw/apps/LayerNorm/check_sole.py
```

Requires `sole_test_out.txt` (written by the simulation) and `sole_test_config.txt` (pre-generated, already present in `sim/t0/`).

---

## 📊 Sample Output

Captured from a SW-only simulation run:

```text
Loading SoleShared into XMEM at 0x40000000
Loaded 1684 bytes (num_vectors=197, channels=384)

Accelerator Disabled
Running 197 vectors
BATCH START base=0 batch=80 bytes=30720
BATCH DONE base=0
BATCH START base=80 batch=80 bytes=30720
BATCH DONE base=80
BATCH START base=160 batch=37 bytes=14208
BATCH DONE base=160

 *** Total: 51736947 K5 cycles | Per-vector avg: 262624 cycles (197 vectors) ***

 Cycle breakdown (197 vectors):
   Reg writes  : 0 total | 0/vec
   Poll DONE   : 0 total | 0/vec
   Compute(SW) : 44593455 total | 226362/vec
   Batch load  : 3754585 total | 19058/vec
   Batch store : 2855721 total | 14496/vec
   Printf      : 494786 total | 2511/vec
   Misc/other  : 38400 total | 194/vec

Check output vs golden reference
  vec 000: MAE=0.2966%  PASS
  vec 001: MAE=0.6716%  PASS
  ...
  vec 196: MAE=0.7574%  PASS

Vectors tested : 197
Vectors passed : 197 / 197  (MAE < 5%)
Average MAE    : 0.6814%
GREAT! Test Passed  --  Avg MAE=0.6814%
```

---

## 🛠️ Build Artifacts

Running `launch_k5_app LayerNorm` (with or without `-ccd1 XON`) automatically compiles `sole_ref.c` and produces:

| File | Type | Purpose |
|---|---|---|
| `build/LayerNorm.elf` | Executable | Compiled application binary |
| `build/instr_loadmem.txt` | Memory | Instruction memory for simulation (`$readmemh`) |
| `build/data_loadmem.txt` | Memory | Data memory for simulation (`$readmemh`) |

Refer to the [root README](../../../README.md) for full environment setup and run instructions.
