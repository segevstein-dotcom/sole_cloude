import struct
import os
import sys

# ── Configuration ─────────────────────────────────────────────────────────────

DATA_DIR  = "data/quantized_noclip"
LUT_PATH  = "data/lut/lut_inv_sqrt.txt"

MAX_CHANNELS      = 384
INV_SQRT_LUT_SIZE = 256
SHARED_SIZE       = 2068   # must match sizeof(SoleShared) in sole_ref.c

# ── Helpers ───────────────────────────────────────────────────────────────────

def read_lines(path):
    with open(path, 'r') as f:
        return [l.strip() for l in f if l.strip() and not l.startswith('#')]

def bytes_hex(data, per_line=32):
    out = []
    for i in range(0, len(data), per_line):
        out.append(' '.join(f'{b:02x}' for b in data[i:i+per_line]))
    return '\n'.join(out) + '\n'

def load_quantized_param(filename):
    lines = read_lines(os.path.join(DATA_DIR, filename))
    n     = int(lines[0])
    scale = float(lines[1])
    zp    = int(lines[2])
    vals  = [int(lines[3+i]) for i in range(n)]
    return vals, scale, zp

def load_golden(path):
    """Load 384 float values from PyTorch golden reference."""
    output = []
    reading = False
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if 'Output:' in line:
                reading = True
            elif reading and line:
                output.append(float(line))
    return output

# ── Load shared data ──────────────────────────────────────────────────────────

lines        = read_lines(os.path.join(DATA_DIR, "global_params.txt"))
num_channels = int(lines[0])
num_vectors  = int(lines[1])
global_s     = float(lines[2])
global_zp    = int(lines[3])

alpha_lines   = read_lines(os.path.join(DATA_DIR, "alpha_factors.txt"))
alpha_factors = [int(alpha_lines[1+i]) for i in range(num_channels)]

gamma_q, gamma_scale, gamma_zp = load_quantized_param("gamma_quantized.txt")
beta_q,  beta_scale,  beta_zp  = load_quantized_param("beta_quantized.txt")

lut = [int(v) for v in read_lines(LUT_PATH)]

# ── Pack binary blob (must match sole_ref.c) ──────────────────────────────────
#
# SoleShared (2068 bytes):
#  Offset  Size   Field
#       0     4   num_vectors        (int32)
#       4     4   num_channels       (int32)
#       8     4   global_zp          (int32)
#      12     4   gamma_zp           (int32)
#      16     4   beta_zp            (int32)
#      20   384   alpha_factors      (int8  x 384)
#     404   384   gamma_q            (uint8 x 384)
#     788   384   beta_q             (uint8 x 384)
#    1172   512   inv_sqrt_lut       (uint16 x 256)
#    1684   384   zero_points        (uint8 x 384)
#    ----
#    2068   total
#
# Then: num_vectors x 384 bytes (quantized values per vector)

buf = bytearray()

# SoleShared header (5 x int32 = 20 bytes)
buf += struct.pack('<i', num_vectors)
buf += struct.pack('<i', num_channels)
buf += struct.pack('<i', global_zp)
buf += struct.pack('<i', gamma_zp)
buf += struct.pack('<i', beta_zp)

# Shared arrays
for a in alpha_factors: buf += struct.pack('b', a)              # int8  x 384
for g in gamma_q:       buf += struct.pack('B', g)              # uint8 x 384
for b in beta_q:        buf += struct.pack('B', b)              # uint8 x 384
for v in lut:           buf += struct.pack('<H', v)             # uint16 x 256
for i in range(num_channels): buf += struct.pack('B', global_zp & 0xFF)  # zero_points

assert len(buf) == SHARED_SIZE, f"Expected {SHARED_SIZE} bytes shared, got {len(buf)}"

# Per-vector data + collect golden refs
all_golden = []

for vi in range(num_vectors):
    vec_lines = read_lines(os.path.join(DATA_DIR, "vectors", f"vector_{vi:03d}.txt"))
    vector    = [int(vec_lines[1+i]) for i in range(num_channels)]
    for v in vector: buf += struct.pack('B', v)

    golden_path = os.path.join(DATA_DIR, "golden_refs", f"golden_ref_vec{vi:03d}.txt")
    all_golden.append(load_golden(golden_path))

total_size = SHARED_SIZE + num_vectors * num_channels
assert len(buf) == total_size, f"Expected {total_size} bytes total, got {len(buf)}"

with open("sole_test_in.txt", 'w') as f:
    f.write(bytes_hex(bytes(buf)))

# ── Write reference file for check_sole.py ───────────────────────────────────

with open("sole_test_config.txt", 'w') as f:
    f.write(f"gamma_scale  {gamma_scale:.10f}\n")
    f.write(f"beta_scale   {beta_scale:.10f}\n")
    f.write(f"gamma_zp     {gamma_zp}\n")
    f.write(f"beta_zp      {beta_zp}\n")
    f.write(f"num_channels {num_channels}\n")
    f.write(f"num_vectors  {num_vectors}\n")
    f.write("beta_q " + " ".join(str(b) for b in beta_q) + "\n")
    for vi, golden in enumerate(all_golden):
        f.write(f"golden_{vi:03d} " + " ".join(f"{v:.6f}" for v in golden) + "\n")

print(f"Generated sole_test_in.txt ({len(buf)} bytes) and sole_test_config.txt ({num_vectors} vectors)")
