"""
check_sole.py
=============
Reads sole_test_out.txt (raw int8 bytes from K5 — num_vectors x 384),
dequantizes each vector, and compares against the PyTorch golden reference.
Reports per-vector MAE and overall average MAE.

Dequantization formula (Method D):
    y_real[i] = y_int8[i] * gamma_scale + b_q[i] * (beta_scale - gamma_scale)
    where b_q[i] = beta_q[i] - beta_zp
"""

# ── helpers ───────────────────────────────────────────────────────────────────

def read_hex_file(path):
    """Read space/newline-separated hex bytes. Returns list of ints (0-255)."""
    vals = []
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            for token in line.split():
                vals.append(int(token, 16))
    return vals


def read_config(path):
    """Parse sole_test_config.txt into a dict."""
    cfg = {}
    with open(path, 'r') as f:
        for line in f:
            parts = line.strip().split()
            if not parts:
                continue
            key = parts[0]
            if key == 'beta_q':
                cfg['beta_q'] = [int(v) for v in parts[1:]]
            elif key.startswith('golden_'):
                cfg[key] = [float(v) for v in parts[1:]]
            elif key in ('gamma_zp', 'beta_zp', 'num_channels', 'num_vectors'):
                cfg[key] = int(parts[1])
            else:
                cfg[key] = float(parts[1])
    return cfg


def compute_mae_pct(y_float, golden):
    """Return MAE as % of output range."""
    out_range = max(golden) - min(golden)
    if out_range < 1e-6:
        return 0.0
    mae = sum(abs(y_float[i] - golden[i]) for i in range(len(golden))) / len(golden)
    return mae / out_range * 100.0


# ── main ──────────────────────────────────────────────────────────────────────

cfg          = read_config("sole_test_config.txt")
raw          = read_hex_file("sole_test_out.txt")

gamma_scale  = cfg['gamma_scale']
beta_scale   = cfg['beta_scale']
beta_zp      = cfg['beta_zp']
beta_q       = cfg['beta_q']
num_channels  = cfg['num_channels']
num_vectors   = cfg['num_vectors']
scale_diff    = beta_scale - gamma_scale

# Use actual output size — supports partial runs (e.g. DEBUG mode with 5 vectors)
actual_vectors = len(raw) // num_channels
if actual_vectors < num_vectors:
    print(f"[DEBUG] Output contains {actual_vectors} vectors (expected {num_vectors})")

total_mae    = 0.0
passed_count = 0

for vi in range(actual_vectors):

    # Extract this vector's output bytes
    start  = vi * num_channels
    y_int8 = [(b if b < 128 else b - 256) for b in raw[start:start + num_channels]]

    # Dequantize
    y_float = [
        y_int8[i] * gamma_scale + (beta_q[i] - beta_zp) * scale_diff
        for i in range(num_channels)
    ]

    golden  = cfg[f'golden_{vi:03d}']
    mae_pct = compute_mae_pct(y_float, golden)
    total_mae += mae_pct

    if mae_pct < 5.0:
        passed_count += 1

    print(f"  vec {vi:03d}: MAE={mae_pct:.4f}%  {'PASS' if mae_pct < 5.0 else 'FAIL'}")

avg_mae = total_mae / actual_vectors

print(f"\nVectors tested : {actual_vectors}")
print(f"Vectors passed : {passed_count} / {actual_vectors}  (MAE < 5%)")
print(f"Average MAE    : {avg_mae:.4f}%")

if avg_mae < 5.0:
    print(f"GREAT! Test Passed  --  Avg MAE={avg_mae:.4f}%")
else:
    print(f"ERROR! Test Failed  --  Avg MAE={avg_mae:.4f}%")
