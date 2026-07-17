# LayerNorm Software Integration

## Purpose
This application handles the software-side integration for the LayerNorm hardware accelerator. It is responsible for programming the host memory mapped registers to configure the accelerator, initializing the memory with input feature maps, starting the computation, and reading back the normalized output.

## Software-to-Hardware Interaction
The K5 architecture allows the host CPU to interact with the accelerator through a defined set of hardware registers.

The software flow is as follows:
1. **Memory Allocation:** The CPU allocates buffers in shared memory for the Input Data, Output Data, and Shared Parameters.
2. **Register Programming:** The software writes the relevant configuration data into the accelerator's host registers (`host_regs`):
    * `Reg 0`: Shared memory address (`SOLE_SHARED_ADDR_REG_IDX`)
    * `Reg 1`: Input memory address (`SOLE_INPUT_ADDR_REG_IDX`)
    * `Reg 2`: Output memory address (`SOLE_OUTPUT_ADDR_REG_IDX`)
    * `Reg 3`: Number of channels (`SOLE_NUM_CH_REG_IDX`)
3. **Execution Start:** The software writes `1` to `Reg 4` (`SOLE_START_REG_IDX`) to signal the hardware to begin.
4. **Polling for Completion:** The software polls `Reg 5` (`SOLE_DONE_REG_IDX`). The hardware sets this "done sticky bit" to `1` when the LayerNorm computation is finished.
5. **Result Validation:** The software reads the processed data from the output memory address and validates the results against a pure-software reference implementation of Layer Normalization.

*(Note: The `C` source code representing this logic is automatically fetched and compiled from the central environment repository into the `build/` folder during the build process.)*

## Build Instructions
To compile the software and generate the memory loading artifacts (`instr_loadmem.txt` and `data_loadmem.txt`):

```bash
launch_k5_app LayerNorm -ccd1 XON
```
Or, if running manually via the underlying script:
```bash
$K5_ENV/sw/sw_utils/comp_app_local_rc3.sh LayerNorm _SPMT_ "-DXON -D_XBOX_" _MAX10_FPGA_ 24576
```

## Run Instructions
Execute the compiled software on the simulated hardware:
```bash
launch_k5_sim LayerNorm
```

## Expected Output Artifacts
After a successful build, the `build/` directory will contain:
* `LayerNorm.elf`: The compiled ELF binary.
* `LayerNorm.s19`: Motorola S-Record format for memory flashing.
* `instr_loadmem.txt`: Instruction memory loaded by the Verilog `$readmemh` system task.
* `data_loadmem.txt`: Data memory loaded by the Verilog `$readmemh` system task.

## Common Errors & Troubleshooting
* **Missing `build/` Folder**: If you attempt to run `launch_k5_sim` and the simulation complains about missing memory files, ensure you ran `launch_k5_app` first. The `build/` folder is explicitly excluded from version control because it is generated.
