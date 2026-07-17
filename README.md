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

## 💡 Hardware Optimizations

This accelerator implements several critical synthesis optimizations to maximize performance and minimize logic utilization. For a full breakdown of the pipeline, see the [Hardware README](hw/xlrs/LayerNorm/README.md).

### 1️⃣ LUT-based Inverse Square Root
Computing $\frac{1}{\sqrt{\sigma^2 + \epsilon}}$ typically requires massive division and square-root hardware. Instead, the `PreProcess` stage clamps the 32-bit variance down to an 8-bit index (`var_hw >> 8`) and fetches a pre-calculated 16-bit `inv_std` from a **Look-Up Table (LUT)** stored in shared memory.

### 2️⃣ Reciprocal Multiplication (Avoiding Dividers)
Division by constants (like $N=384$ for channel means) is notoriously slow in hardware. The RTL eliminates division entirely by using **reciprocal multiplication**. For example, dividing by 384 is accomplished by multiplying by a precomputed constant (`11184811`) and shifting to extract the top 32 bits:
`mu_abs_q = (ex_in * 11184811) >> 32;`

### 3️⃣ Quantization & Truncation (64-bit to 8-bit)
The internal `Affine` stage performs intermediate calculations in high-precision **64-bit** signed arithmetic to prevent overflow. In the final output pipeline stage, it performs an arithmetic right-shift (`>>> 14`) to safely discard lower fractional bits, and statically clamps the result between `-128` and `127` before casting the final probability distribution back into a compact **8-bit** format.

---

## 🚀 Compile and Run

### 🔧 Initial Setup
In your BIU-Engineering cloud environment, open a terminal anywhere and enter the following command:

```bash
source /project/tsmc65/shared/k5_share/k5_xbox/setup/build_k5_proj_rc3.sh
```

This only needs to be executed once ever, and should take just a few seconds. It will permanently configure your account setup for the environment.

**⚠️ IMPORTANT: Once the setup is complete, close the terminal and open a new one to continue with the next steps!**

### 📂 Your Personal Working Environment
First, clone the repository and rename it:
```bash
tsmc65
git clone <repository_url>
mv LayerNorm my_k5_proj
cd $ws/my_k5_proj
ls -l
```

You will find three sub-folders:
- `sw`: For software applications
- `hw`: For hardware accelerators
- `sim`: For simulation workspace

### 🖥️ Running the Layernorm Application
To run our SOC SW application in simulation, we need to open two terminal sessions:
- **Terminal-1**: Software application User Interface
- **Terminal-2**: Hardware Verilog Simulation for SOC platform and acceleration logic

The two terminal sessions will invisibly communicate with each other.

Open two separate terminals and in each of them run:

```bash
set_k5_terminal
```

In one of the two terminals (doesn't matter which) start the application by:

```bash
launch_k5_app LayerNorm -ccd1 XON
```

The `-ccd1` flag is used to pass conditional compile definitions to the C application.

In the other terminal start the simulation session by:

```bash
launch_k5_sim LayerNorm
```

The two terminal sessions will wait each for the other and will proceed to simulation once both are started.
The prints from the application C code will show up on the application launching terminal.

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
