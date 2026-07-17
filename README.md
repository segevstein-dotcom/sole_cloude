# 🧮 LayerNorm Implementation

## 📋 Table of Contents
1. [Layer Normalization](#-layer-normalization)
2. [Compile and Run](#-compile-and-run)
3. [Results](#-results)
4. [Software](#-software)
5. [Hardware](#-hardware)

---

## 🔢 Layer Normalization

Layer Normalization transforms a vector of inputs by normalizing them across the feature dimension. It is widely used in Deep Learning models (like Transformers) to stabilize training and inference.

$$
\text{Layernorm}(X_i)= \frac{X_i - \mu}{\sqrt{\sigma^2 + \epsilon}} \cdot \gamma + \beta
$$

Where $\mu$ is the mean, $\sigma^2$ is the variance, $\gamma$ is the scaling factor, and $\beta$ is the bias.

### 🔍 Our Implementation

Our solution uses a hardware accelerator on the K5 architecture to offload the mathematical complexity (statistical accumulations, zero-point handling, affine transformations) into hardware:

```text
┌─────────┐    ┌────────────┐    ┌──────────────┐    ┌───────────┐    ┌──────────┐
│  Input  │    │ Zero-Point │    │ Mean & Var   │    │  Affine   │    │  Output  │
│ Vector  │───►│ Extraction │───►│(E[x], E[x²]) │───►│ Transform │───►│  Vector  │
└─────────┘    └────────────┘    └──────────────┘    └───────────┘    └──────────┘
```

**Key Features:**
- 📊 Sequential pipelined arithmetic (`ZP` $\rightarrow$ `EX/EX2` $\rightarrow$ `PreProcess` $\rightarrow$ `Affine`)
- 🔄 Dual-mode: software reference or hardware-accelerated RTL logic
- ⚡ Optimized for resource efficiency and host-CPU latency reduction

For a more detailed explanation of the architecture, see the [Architecture section in the Hardware README](hw/xlrs/LayerNorm/README.md).

For software integration details, see the [Software README](sw/apps/LayerNorm/README.md).

---

## 🚀 Compile and Run

### 🔧 Initial Setup
In your K5 environment, ensure you have sourced the base setup script. This configures the `$K5_ENV` and `$K5_XBOX_ENV` variables:

```bash
source /path/to/k5_rc3_setup.sh
```

### 🖥️ Running the LayerNorm Application
To run the application, you compile the software memory images and run the simulation.

Compile the application (generates `instr_loadmem.txt` and `data_loadmem.txt`):
```bash
launch_k5_app LayerNorm -ccd1 XON
```

Run the hardware simulation (Cadence Xcelium):
```bash
launch_k5_sim LayerNorm
```

### 🚩 Available Flags
| Flag | Description |
|------|-------------|
| `XON` | Enable the hardware accelerator logic |

---

## 📊 Results

The simulation runs the application test logic, passing simulated inputs through the RTL.

Upon successful execution, the output will log the vector stages advancing sequentially:
```text
LayerNorm RTL: START vector 0
DBG VEC0: shared=0x00000000 in=0x00000100 out=0x00000200 mu=128 inv_std=5 min_alpha=1 global_zp=0 gamma_zp=0 beta_zp=0
LayerNorm RTL: DONE vector 0
```
