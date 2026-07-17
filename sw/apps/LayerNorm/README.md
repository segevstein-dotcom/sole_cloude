# 💻 LayerNorm Software Integration

## 📘 Overview
This directory handles the software-side integration for the LayerNorm hardware accelerator. It is responsible for programming the host memory-mapped registers, initializing shared memory, and interacting with the FPGA/RTL.

---

## 🗂️ File Structure

| File | Type | Purpose |
|------|------|---------|
| `build/LayerNorm.elf` | Executable | Compiled application binary |
| `build/LayerNorm.s19` | Firmware | S-Record format for memory flashing |
| `build/instr_loadmem.txt` | Memory | Instruction memory for simulation (`$readmemh`) |
| `build/data_loadmem.txt` | Memory | Data memory for simulation (`$readmemh`) |

*(Note: The core C source code is fetched from the central environment repository into the `build/` folder during compilation).*

---

## 🔌 Software-to-Hardware Interaction

The K5 architecture allows the host CPU to interact with the accelerator through a defined set of hardware registers.

### 📝 Register Map

| Register | Name | Description |
|----------|------|-------------|
| `Reg 0` | `SOLE_SHARED_ADDR_REG_IDX` | Address pointer for quantization/scaling parameters |
| `Reg 1` | `SOLE_INPUT_ADDR_REG_IDX` | Address pointer for input feature maps |
| `Reg 2` | `SOLE_OUTPUT_ADDR_REG_IDX` | Address pointer for normalized output |
| `Reg 3` | `SOLE_NUM_CH_REG_IDX` | Number of channels / vector length |
| `Reg 4` | `SOLE_START_REG_IDX` | Write `1` to start the computation |
| `Reg 5` | `SOLE_DONE_REG_IDX` | Poll for `1` to detect completion (sticky bit) |

### 🔄 Execution Flow
1. **Memory Allocation:** Allocate buffers in shared memory for Input Data, Output Data, and Shared Parameters.
2. **Register Programming:** Write addresses and channel counts to `Reg 0` through `Reg 3`.
3. **Trigger:** Write `1` to `Reg 4` (`SOLE_START_REG_IDX`).
4. **Polling:** Poll `Reg 5` (`SOLE_DONE_REG_IDX`) until the hardware sets it to `1`.
5. **Validation:** Read the processed output memory and validate against the software reference.

---

## 🛠️ Usage

### Build Instructions
To compile the software and generate the memory loading artifacts (`instr_loadmem.txt` and `data_loadmem.txt`):
```bash
launch_k5_app LayerNorm -ccd1 XON
```

### Run Instructions
Execute the compiled software on the simulated hardware:
```bash
launch_k5_sim LayerNorm
```

### ⚠️ Common Errors
| Error Type | Description |
|------------|-------------|
| 📁 **Missing Files** | Simulation complains about missing `.txt` files. Ensure you ran `launch_k5_app` first. |
| 🛑 **Command Not Found** | Ensure `$K5_ENV` is sourced via the environment setup scripts. |
