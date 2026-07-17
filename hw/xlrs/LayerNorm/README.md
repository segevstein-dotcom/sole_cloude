# LayerNorm Hardware Accelerator Architecture

## Purpose
This directory contains the SystemVerilog Register Transfer Level (RTL) implementation of a hardware accelerator designed to perform Layer Normalization (`LayerNorm`). By offloading the math-intensive statistical calculations and affine transformations, the host CPU experiences massive latency reductions when evaluating Deep Learning workloads.

## High-Level Architecture
The accelerator is designed as a sequential multi-stage processing pipeline. It utilizes an internal Finite State Machine (FSM) to coordinate memory reads, calculations, and memory writes over a shared memory interface.

### Module Hierarchy
* **`LayerNorm.sv`**: The Top-level wrapper module. It manages the FSM, register mapping, memory request muxing, and interconnects the functional stages.
  * **`zp_stage`** (`zp.sv`): Extracts zero-point and quantization parameters from shared memory.
  * **`ex_ex2_stage`** (`ex_ex2.sv`): Streams input feature maps and accumulates the sum (`E[x]`) and sum of squares (`E[x^2]`).
  * **`preprocess_stage`** (`PreProcess.sv`): Computes statistical parameters like mean (`mu`) and inverse standard deviation (`inv_std`) using the accumulated moments.
  * **`affine_stage`** (`Affine.sv`): Performs the actual normalization and affine transformation (`y = gamma * ((x - mu) * inv_std) + beta`) accounting for scaling (`min_alpha`).

## Register Interface
The hardware relies on a set of 32-bit `host_regs` for configuration:
* `host_regs[0]`: `shared_addr` (Memory pointer to quantization/scaling parameters)
* `host_regs[1]`: `input_addr` (Memory pointer to input activations)
* `host_regs[2]`: `output_addr` (Memory pointer for output activations)
* `host_regs[3]`: `num_channels` (Size of the vector/feature map)
* `host_regs[4]`: `start_layernorm` (Start trigger pulse)
* `host_regs_data_out[5]`: `layernorm_done` (Hardware done indicator)

## Data Flow & Processing Sequence (FSM)
1. **`IDLE`**: Hardware waits for a `start_layernorm` trigger from the host.
2. **`ZP`**: Reads `global_zp`, `gamma_zp`, and `beta_zp` from `shared_addr`.
3. **`EX_EX2`**: Scans the input activations to calculate aggregate statistics (`ex`, `ex2`, and minimum scaling alpha).
4. **`PREPROCESS`**: Resolves `mu` (mean) and `inv_std` (inverse standard deviation).
5. **`AFFINE`**: Passes through the input memory again, normalizing each activation with `mu` and `inv_std`, applying the `gamma`/`beta` shift, and writing the quantized result to `output_addr`.
6. **`DONE`**: Asserts the sticky done bit in the host register map.

## Simulation & Verification
Verification is handled by standalone testbenches (`tb_*.sv`) mapping directly to the individual stages.

### Running Simulation
The simulation is executed via Xcelium:
```bash
launch_k5_sim LayerNorm
```
The simulation runs the application test logic, passing simulated inputs through the RTL.

### Expected Simulation Output
During `PREPROCESS -> AFFINE` transitions, debug monitors print vector characteristics. An example Xcelium log excerpt:
```text
LayerNorm RTL: START vector 0
DBG VEC0: shared=0x00000000 in=0x00000100 out=0x00000200 mu=128 inv_std=5 min_alpha=1 global_zp=0 gamma_zp=0 beta_zp=0
LayerNorm RTL: DONE vector 0
```

## Important Files
* **`.sv` files**: Standard SystemVerilog RTL and testbenches.
* **`LayerNorm.f`**: File list specifying the paths to all required Verilog sources for the simulator.
* **`LayerNorm.qpf` / `.qsf`**: Intel Quartus project configuration files for logic synthesis and timing constraint evaluations.
