# AILayerNorm — Hardware Accelerator for Layer Normalization

FPGA implementation of a hardware accelerator for quantized Layer Normalization,
based on the **SOLE** algorithm.
The accelerator runs on a **K5-XBOX SoC** targeting a **MAX 10 FPGA** (10M50DAF484C7G).

---

## Key Results

| Metric | Initial (parallel arch.) | Final (serial arch.) | Improvement |
|---|---|---|---|
| Logic Elements (synthesis) | 450,742 | **5,878** | ×77 reduction |
| Logic Elements (post-fitter) | — | 4,769 | — |
| Max Frequency | 6.87 MHz | **54.22 MHz** | ×7.9 |
| System speedup (vs SW) | — | ×7.59 overall | ×224.6 compute-only |
| Vectors tested | — | 197 / 197 PASS | — |
| Average MAE% | — | **0.6814%** | threshold: 5% |

> **Note on Logic Element count:** The synthesis tool (`qsyn_xlr`) reports **5,878 LEs**
> from the mid-flow map/synthesis stage. After Place & Route, the Quartus Fitter applies
> additional LUT and register merging, reducing the final on-chip count to **4,769 LEs**.
> Both numbers are correct and refer to different stages of the implementation flow.

---

## Repository Structure

```
my_k5_proj/
├── hw/
│   └── xlrs/
│       └── LayerNorm/          # RTL source + synthesis + testbenches
│           ├── LayerNorm.sv    # Top-level module + FSM
│           ├── zp.sv           # Stage 1: Zero Point extraction
│           ├── ex_ex2.sv       # Stage 2: E[x] / E[x²] accumulation
│           ├── PreProcess.sv   # Stage 3: μ, σ⁻¹ via reciprocal multiply + LUT
│           ├── Affine.sv       # Stage 4: per-channel affine transform (chunk pipeline)
│           ├── tb_*.sv         # Standalone testbenches for each stage
│           ├── LayerNorm.f     # Xcelium file-list for simulation
│           ├── LayerNorm.qsf / .qpf  # Quartus project files
│           └── qsyn_output_files/   # Synthesis / STA reports
│               └── README.md   # ← HW architecture details
└── sw/
    └── apps/
        └── LayerNorm/          # SW application running on K5 RISC-V core
            ├── sole_ref.c      # Main app: SW reference + HW accelerator driver
            ├── gen_sole_test.py # Generates test input and config files
            ├── check_sole.py   # Evaluates output accuracy (MAE%)
            ├── build/          # Pre-built RISC-V binaries (loadmem format)
            └── README.md       # ← SW application details
```

Simulation working directory: `sim/` (contains pre-generated test data in `sim/t0/`).

---

## Environment Prerequisites

The K5-XBOX simulation environment must be set up before running anything.
This is a course-specific infrastructure; the relevant paths below assume the
standard RC3 cloud setup:

```bash
# Required environment variables (set by the K5 RC3 setup script):
export K5_ENV=/project/tsmc65/shared/k5_share/kuntz5
export K5_XBOX_ENV=/project/tsmc65/shared/k5_share/k5_xbox
export MY_K5_XLRS=/data/project/tsmc65/users/$USER/ws/my_k5_proj/hw/xlrs

# Add Xcelium simulator to PATH:
export PATH="/tools/cadence/XCELIUM/23.09.013/tools.lnx86/bin:$PATH"
```

---

## How to Run the Simulation

The K5 environment provides two wrapper commands: `launch_k5_app` (Python server)
and `launch_k5_sim` (Xcelium). Both must run from `sim/` in separate terminals.

### SW-only mode (pure RISC-V software, no HW accelerator)

```bash
# Terminal 1 — Python server:
cd sim/
launch_k5_app LayerNorm

# Terminal 2 — Xcelium simulation:
cd sim/
launch_k5_sim LayerNorm
```

### HW-accelerated mode (RTL accelerator active)

```bash
# Terminal 1 — Python server with XON flag:
cd sim/
launch_k5_app LayerNorm -ccd1 XON

# Terminal 2 — Xcelium simulation (identical to SW-only):
cd sim/
launch_k5_sim LayerNorm
```

> XON is a software-side flag only: it controls whether `sole_ref.c` calls
> `layernorm_xlr()` (HW) or `layernorm_nox()` (SW). The RTL is always compiled
> into the simulation regardless of mode.

The simulation ends automatically after all test vectors are processed.
`check_sole.py` is called by the application at the end to report accuracy.

---

## Synthesis

Synthesis uses the course `qsyn_xlr` wrapper around Quartus Prime 24.1:

```bash
cd hw/xlrs/LayerNorm/
qsyn_xlr LayerNorm -all      # full flow: synthesis + fit + STA
```

Results are written to `qsyn_output_files/`.

---

## Further Documentation

- [Software application details](sw/apps/LayerNorm/README.md)
- [Hardware architecture details](hw/xlrs/LayerNorm/README.md)
