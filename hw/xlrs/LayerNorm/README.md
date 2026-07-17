# 🔢 LayerNorm Hardware Accelerator

## 📘 Overview

This project implements a modular hardware accelerator for the **Layer Normalization function**. By offloading the math-intensive statistical calculations and affine transformations, the host CPU experiences massive latency reductions.

The design is written in **SystemVerilog** and implements a sequential Finite State Machine (FSM) pipeline to compute variance, standard deviation, and normalization.

---

## 🧱 Architecture

```text
LayerNorm.sv (top-level)
 ├── zp.sv          // Extracts zero-point and quantization params
 ├── ex_ex2.sv      // Accumulates E[x] (sum) and E[x²] (sum of squares)
 ├── PreProcess.sv  // Computes mean (mu) and inverse std deviation (inv_std)
 └── Affine.sv      // Applies normalization: y = gamma * ((x - mu) * inv_std) + beta
```

---

## 🧩 Module Descriptions

### 🔹 `LayerNorm.sv` *(Top-Level Module)*
**Role**: Orchestrates the LayerNorm operation pipeline.

**Responsibilities**:
* Exposes `host_regs` (0 to 5) for configuration and start/done signaling.
* Multiplexes memory requests (`mem_intf_read`, `mem_intf_write`) for all underlying stages.
* Manages the global FSM states.

---

### 🔹 `zp.sv` (`zp_stage`)
**Role**: Fetches necessary quantization zero-points and scaling factors.

**Responsibilities**:
* Reads `global_zp`, `gamma_zp`, and `beta_zp` from the `shared_addr`.

---

### 🔹 `ex_ex2.sv` (`ex_ex2_stage`)
**Role**: Scans input activations to accumulate statistical moments.

**Responsibilities**:
* Accumulates the sum of inputs (`E[x]`).
* Accumulates the sum of squares (`E[x²]`).
* Determines the minimum scaling factor (`min_alpha`).

---

### 🔹 `PreProcess.sv` (`preprocess_stage`)
**Role**: Resolves final mean and inverse standard deviation.

**Responsibilities**:
* Computes `mu` (mean) from `E[x]`.
* Computes `inv_std` (inverse standard deviation) from `E[x]` and `E[x²]`.

---

### 🔹 `Affine.sv` (`affine_stage`)
**Role**: Computes and outputs the final normalized values:

$$
y = \gamma \cdot \left((x-\mu)\cdot \texttt{inv\_std}\right)+\beta
$$

Where `inv_std` is the **inverse standard deviation** ($\frac{1}{\sqrt{\sigma^2 + \epsilon}}$) computed by the `PreProcess` stage.

**Responsibilities**:
* Reads input data a second time.
* Applies normalization and shifts.
* Writes normalized vectors to `output_addr`.

---

## 🧮 Pipeline Summary (FSM)

| State | Module | Function |
|-------|--------|----------|
| 1️⃣ `IDLE` | FSM | Waits for `start_layernorm` trigger |
| 2️⃣ `ZP` | `zp_stage` | Fetches quantization params |
| 3️⃣ `EX_EX2` | `ex_ex2_stage` | Accumulates moments |
| 4️⃣ `PREPROCESS` | `preprocess_stage`| Computes `mu` and `inv_std` |
| 5️⃣ `AFFINE` | `affine_stage` | Normalizes and outputs data |
| 6️⃣ `DONE` | FSM | Asserts `layernorm_done` to host |

---

## 🛠 Usage

Refer to the [Software README](../../../sw/apps/LayerNorm/README.md) for instructions on how to compile the memory images and run the design.
