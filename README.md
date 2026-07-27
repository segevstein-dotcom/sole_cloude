# 🧮 AILayerNorm — Hardware Accelerator for Layer Normalization

FPGA implementation of a hardware accelerator for quantized Layer Normalization, based on the **SOLE** algorithm.
The accelerator runs on a **K5-XBOX SoC** targeting a **MAX 10 FPGA** (10M50DAF484C7G).

## 📋 Table of Contents
1. [Layer Normalization](#-layer-normalization)
2. [Key Results](#-key-results)
3. [Our Implementation](#-our-implementation)
4. [Hardware Optimizations](#-hardware-optimizations)
5. [Repository Structure](#-repository-structure)
6. [Compile and Run](#-compile-and-run)
7. [Synthesis](#-synthesis)
8. [Sample Output](#-sample-output)

---

## 🔢 Layer Normalization

Layer Normalization transforms a vector of inputs by normalizing them across the feature dimension. It is widely used in Deep Learning models (like Transformers) to stabilize training and inference:

$$
\text{LayerNorm}(X_i)= \frac{X_i - \mu}{\sqrt{\sigma^2}} \cdot \gamma + \beta
$$

Where $\mu$ is the mean, $\sigma^2$ is the variance, $\gamma$ is the per-channel scale, and $\beta$ is the per-channel bias.

This project implements **AILayerNorm**, the low-precision, fixed-point variant of this computation proposed in the SOLE paper (Wang et al., ICCAD 2023), targeting resource- and timing-constrained edge FPGA platforms.

---

## 📊 Key Results

| Metric | Initial (parallel arch.) | Final (serial arch.) | Improvement |
|---|---|---|---|
| Logic Elements (synthesis / map) | 450,742 | **5,878** | ×77 reduction |
| Logic Elements (post-fitter / P&R) | — | 4,769 | — |
| Max Frequency | 6.87 MHz | **54.22 MHz** | ×7.9 |
| System speedup (vs. SW) | — | ×7.59 overall | ×224.6 compute-only |
| Vectors tested | — | 197 / 197 PASS | — |
| Average MAE% | — | **0.6814%** | acceptance threshold: 5% |

> **Note on Logic Element count:** The synthesis tool (`qsyn_xlr`) reports **5,878 LEs** from the mid-flow map/synthesis stage. After Place & Route, the Quartus Fitter applies additional LUT and register merging, reducing the final on-chip count to **4,769 LEs**. Both numbers are correct and refer to different stages of the implementation flow.

---

## 🔍 Our Implementation

Our solution uses a hardware accelerator on the K5 architecture to offload the mathematical complexity (statistical accumulation, zero-point handling, affine transformation) into hardware:

```text
┌─────────┐    ┌────────────┐    ┌──────────────┐    ┌───────────┐    ┌──────────┐
│  Input  │    │ Zero-Point │    │ Mean & Var   │    │  Affine   │    │  Output  │
│ Vector  │───►│ Extraction │───►│(E[x], E[x²]) │───►│ Transform │───►│  Vector  │
└─────────┘    └────────────┘    └──────────────┘    └───────────┘    └──────────┘
      (ZP)                            (EX_EX2)         (PreProcess)     (Affine)
```

**Key Features:**
- 📊 Four sequential pipelined stages (`ZP → EX_EX2 → PreProcess → Affine`), each with a `start`/`done` handshake to a single top-level FSM
- 🔄 Dual-mode operation: pure software reference (`layernorm_nox`) or hardware-accelerated RTL (`layernorm_xlr`), selectable via a compile-time flag
- ⚡ Channel-sequential (single-channel-per-cycle) datapath, chosen after an initial 32-channel-parallel architecture proved unsynthesizable (see [Hardware README](hw/xlrs/LayerNorm/README.md))
- ✅ Verified bit-exact against a golden C reference at every pipeline stage and at full-system granularity (197/197 vectors)

For a more detailed explanation of the architecture, see the [Hardware README](hw/xlrs/LayerNorm/README.md).
For software integration details, see the [Software README](sw/apps/LayerNorm/README.md).

---

## 💡 Hardware Optimizations

This accelerator implements several critical synthesis optimizations to maximize performance and minimize logic utilization. For the full optimization journey (a multi-round timing-closure process), see the [Hardware README](hw/xlrs/LayerNorm/README.md).

### 1️⃣ LUT-based Inverse Square Root
Computing $1/\sqrt{\sigma^2}$ typically requires expensive division and square-root hardware. Instead, the `PreProcess` stage clamps the computed variance down to an 8-bit index (`var_hw >> 8`) and fetches a pre-calculated 16-bit `inv_std` from a 256-entry **Look-Up Table (LUT)** stored in shared memory.

### 2️⃣ Reciprocal Multiplication (Avoiding Dividers)
Division by the fixed constants used in this design (channel count 384 and its derivative 24) is slow and area-expensive as a general combinational divider — an earlier version of the design used one directly, and it was identified during timing closure as one of several critical-path contributors. The RTL now eliminates division entirely via **reciprocal multiplication**: dividing by 384 is accomplished by multiplying by a precomputed constant and shifting to extract the result:

```systemverilog
// mu_comb: reciprocal-multiply replacement for ex_in / 384
mu_abs_q = (64'(mu_abs_in) * 64'd11184811) >> 32;
```

### 3️⃣ Quantization & Truncation (64-bit to 8-bit)
The `Affine` stage performs intermediate calculations in high-precision **64-bit** signed arithmetic to prevent overflow. In the final step, it performs an arithmetic right-shift (`>>> 14`, with rounding) to discard the fractional bits, then clamps the result to the signed 8-bit range `[-128, 127]` before writing the final output.

### 4️⃣ Channel-Sequential Processing
Rather than processing 32 channels per cycle (which required random-access 384-entry buffers and prevented BRAM inference, consuming ~450,000 Logic Elements), the final design processes **one channel per clock cycle** through small, fixed-size line buffers. This reduced resource usage by ×77 at a compute-time cost of well under 1% of total system latency.

---

## 📁 Repository Structure

```
my_k5_proj/
├── hw/
│   └── xlrs/
│       └── LayerNorm/          # RTL source + synthesis + testbenches
│           ├── LayerNorm.sv    # Top-level module + FSM
│           ├── zp.sv           # Stage 1: Zero-Point extraction
│           ├── ex_ex2.sv       # Stage 2: E[x] / E[x²] accumulation
│           ├── PreProcess.sv   # Stage 3: μ, 1/σ via reciprocal multiply + LUT
│           ├── Affine.sv       # Stage 4: per-channel affine transform (chunk pipeline)
│           ├── tb_*.sv         # Standalone testbenches for each stage
│           ├── LayerNorm.f     # Xcelium file-list for simulation
│           ├── LayerNorm.qsf / .qpf  # Quartus project files
│           ├── qsyn_output_files/    # Synthesis / STA reports
│           └── README.md       # ← Hardware architecture details
└── sw/
    └── apps/
        └── LayerNorm/          # SW application running on the K5 RISC-V core
            ├── sole_ref.c       # Main app: SW reference + HW accelerator driver
            ├── gen_sole_test.py # Generates test input and config files
            ├── check_sole.py    # Evaluates output accuracy (MAE%)
            ├── build/           # Pre-built RISC-V binaries (loadmem format)
            └── README.md        # ← Software application details
```

Simulation working directory: `sim/` (contains pre-generated test data in `sim/t0/`).

---

## 🚀 Compile and Run

### 🔧 Initial Setup
In your BIU-Engineering cloud environment, open a terminal anywhere and run:

```bash
source /project/tsmc65/shared/k5_share/k5_xbox/setup/build_k5_proj_rc3.sh
```

This only needs to be executed **once ever** — it permanently configures your account setup for the environment.

**⚠️ Once setup is complete, close the terminal and open a new one before continuing.**

This generates `$ws/my_k5_proj` with three sub-folders: `sw/` (software applications), `hw/` (hardware accelerators), and `sim/` (simulation workspace) — already containing the source in this repository.

### 🖥️ Running the Simulation

Running requires **two terminal sessions**: one for the software application, one for the RTL simulation. In **each** terminal, first run:

```bash
set_k5_terminal
```

#### SW-only mode (pure RISC-V software, no HW accelerator)

```bash
# Terminal 1 — application:
launch_k5_app LayerNorm

# Terminal 2 — Xcelium simulation:
launch_k5_sim LayerNorm
```

#### HW-accelerated mode (RTL accelerator active)

```bash
# Terminal 1 — application, with the XON flag:
launch_k5_app LayerNorm -ccd1 XON

# Terminal 2 — Xcelium simulation (identical to SW-only):
launch_k5_sim LayerNorm
```

> `XON` is a **software-side flag only**: it controls whether `sole_ref.c` calls `layernorm_xlr()` (hardware) or `layernorm_nox()` (software). The RTL is always compiled into the simulation regardless of mode — only the C driver's behavior changes.

The two terminals synchronize automatically once both are started. `check_sole.py` is invoked automatically at the end of the run to report accuracy.

### 🚩 Available Flags

| Flag | Description |
|---|---|
| `XON` | Enable the hardware accelerator path (`layernorm_xlr`) instead of the pure-software path (`layernorm_nox`) |

---

## 🔨 Synthesis

Synthesis uses the course `qsyn_xlr` wrapper around Quartus Prime 24.1:

```bash
cd hw/xlrs/LayerNorm/
qsyn_xlr LayerNorm -all      # full flow: synthesis + fit + STA
```

Results are written to `qsyn_output_files/`. See the [Hardware README](hw/xlrs/LayerNorm/README.md) for the full synthesis results table and optimization history.

---

## 📊 Sample Output

The following is real output captured from a full HW-accelerated run (197 vectors):

```text
Loading SoleShared into XMEM at 0x40000000
Loaded 1684 bytes (num_vectors=197, channels=384)

Accelerator Enabled
Running 197 vectors
BATCH START base=0 batch=80 bytes=30720
BATCH DONE base=0
...
LayerNorm RTL: START vector 0
LayerNorm RTL: DONE vector 0
...
LayerNorm RTL: START vector 196
LayerNorm RTL: DONE vector 196

Check output vs golden reference
  vec 000: MAE=0.2966%  PASS
  ...
  vec 196: MAE=0.7574%  PASS

Vectors tested : 197
Vectors passed : 197 / 197  (MAE < 5%)
Average MAE    : 0.6814%
GREAT! Test Passed  --  Avg MAE=0.6814%
```

---

## 📚 Further Documentation

- 💻 [Software application details](sw/apps/LayerNorm/README.md)
- 🔩 [Hardware architecture details](hw/xlrs/LayerNorm/README.md)
