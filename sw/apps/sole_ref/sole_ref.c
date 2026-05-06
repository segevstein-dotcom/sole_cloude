#include <k5_libs.h>
#include <stdint.h>

/****************************** CONSTANTS ******************************/

#define MAX_CHANNELS 384
#define MAX_VECTORS  197

/****************************** XMEM LAYOUT ******************************/

// NOTICE: addresses must be compliant with the accelerator SV code. NOT automated.
//
//  Address          Size    Content
//  0x40000000       1696    SoleShared (1684 bytes padded to next 32-byte boundary)
//  0x400006A0        384    Input vector  (uint8 x MAX_CHANNELS)
//  0x40000820        384    Output vector (int8  x MAX_CHANNELS)

#define SHARED_XMEM_ADDR  0x40000000
#define INPUT_XMEM_ADDR   0x400006A0   // SHARED_XMEM_ADDR + 1696
#define OUTPUT_XMEM_ADDR  0x40000820   // INPUT_XMEM_ADDR  + 384

/****************************** APB REGISTER MACROS ******************************/

// NOTICE: indices must be compliant with the register map in the accelerator SV code. NOT automated.

#define SM_REGS_BASE_IDX 0

#define SOLE_SHARED_ADDR_REG_IDX  (SM_REGS_BASE_IDX + 0)
#define SOLE_INPUT_ADDR_REG_IDX   (SM_REGS_BASE_IDX + 1)
#define SOLE_OUTPUT_ADDR_REG_IDX  (SM_REGS_BASE_IDX + 2)
#define SOLE_NUM_CH_REG_IDX       (SM_REGS_BASE_IDX + 3)
#define SOLE_START_REG_IDX        (SM_REGS_BASE_IDX + 4)
#define SOLE_DONE_REG_IDX         (SM_REGS_BASE_IDX + 5)

#define SOLE_SHARED_ADDR_REG  ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + (4*SOLE_SHARED_ADDR_REG_IDX)))
#define SOLE_INPUT_ADDR_REG   ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + (4*SOLE_INPUT_ADDR_REG_IDX)))
#define SOLE_OUTPUT_ADDR_REG  ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + (4*SOLE_OUTPUT_ADDR_REG_IDX)))
#define SOLE_NUM_CH_REG       ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + (4*SOLE_NUM_CH_REG_IDX)))
#define SOLE_START_REG        ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + (4*SOLE_START_REG_IDX)))
#define SOLE_DONE_REG         ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + (4*SOLE_DONE_REG_IDX)))

/****************************** INPUT STRUCTURE ******************************/

/*
 * File layout (sole_test_in.txt):
 *   SoleShared  (1684 bytes) — shared params, loaded once into XMEM
 *   num_vectors x MAX_CHANNELS bytes — one vector per iteration
 *
 * SoleShared layout:
 *  Offset  Size   Field
 *       0     4   num_vectors        (int32)
 *       4     4   num_channels       (int32)
 *       8     4   global_zp          (int32)  — uniform zero point for all channels
 *      12     4   gamma_zp           (int32)
 *      16     4   beta_zp            (int32)
 *      20   384   alpha_factors      (int8  x 384)
 *     404   384   gamma_q            (uint8 x 384)
 *     788   384   beta_q             (uint8 x 384)
 *    1172   512   inv_sqrt_lut       (uint16 x 256)
 *    ----
 *    1684   total
 */

typedef struct {
    int32_t  num_vectors;
    int32_t  num_channels;
    int32_t  global_zp;
    int32_t  gamma_zp;
    int32_t  beta_zp;

    int8_t   alpha_factors[MAX_CHANNELS];
    uint8_t  gamma_q[MAX_CHANNELS];
    uint8_t  beta_q[MAX_CHANNELS];
    uint16_t inv_sqrt_lut[256];

} SoleShared;

/****************************** LUT FOR SQUARE ******************************/

static const uint16_t SQUARE_LUT[16] = {
    0, 1, 4, 9, 16, 25, 36, 49,
    64, 81, 100, 121, 144, 169, 196, 225
};

/****************************** CORE ALGORITHM FUNCTIONS ******************************/

static void dynamic_compress(uint8_t x, uint8_t *c, uint8_t *s)
{
    if (x < 64) {
        *c = (x + 2) >> 2;
        *s = 0;
    } else {
        *c = (x + 8) >> 4;
        *s = 1;
    }

    if (*c > 15) *c = 15;
}

static int8_t find_min_alpha(const int8_t *a, int32_t N)
{
    int32_t i;
    int8_t  m = 127;

    for (i = 0; i < N; i++)
        if (a[i] < m) m = a[i];

    return m;
}

static void stage1(const SoleShared *sh,
                   const uint8_t    *values,
                   int64_t          *Ex,
                   int64_t          *Ex2,
                   int8_t            min_alpha)
{
    int32_t i;

    *Ex  = 0;
    *Ex2 = 0;

    for (i = 0; i < sh->num_channels; i++) {

        int16_t xi =
            (int16_t)values[i] -
            (int16_t)sh->global_zp;

        uint8_t abs_x = (xi < 0) ? -xi : xi;

        uint8_t c, s;
        dynamic_compress(abs_x, &c, &s);

        uint32_t xc2 = (uint32_t)SQUARE_LUT[c] << (4 * s);

        int32_t rel_shift = sh->alpha_factors[i] - min_alpha;

        /* K5 FIX: int64 left-shift may call __ashldi3 (broken on this toolchain).
         * Perform shift in int32/uint32 then widen to int64 for accumulation.
         *   xi  is int16, rel_shift <= 4 → max ±2048, fits in int32.
         *   xc2 is uint32, 2*rel_shift <= 8 → max ~236M, fits in uint32.
         */
        *Ex  += (int64_t)((int32_t)xi  << rel_shift);
        *Ex2 += (int64_t)(xc2 << (2 * rel_shift));
    }
}

static void stage2_improved(const SoleShared *sh,
                             const uint8_t   *values,
                             int64_t          Ex,
                             int64_t          Ex2,
                             int8_t           min_alpha,
                             int8_t          *Y)
{
    int32_t C = sh->num_channels;

    /* K5 FIX: int64/int32 division (__divdi3) is broken on this 32-bit RISC-V
     * toolchain.  All values fit comfortably in int32, so we cast down first.
     *   |Ex|  <= 384 * 128 * 16  =  786432  < 2^31  OK
     *   Ex2   <= 384 * 3600 * 256 = 353894400 < 2^31  OK
     *   (Ex2<<4)/384 = Ex2/24  <=  14745600  < 2^31  OK
     *   mu32^2  <= 2032^2 = 4129024  < 2^31  OK
     */
    int32_t mu32    = (int32_t)Ex / C;          /* int32/int32 — no __divdi3 */
    int64_t mu      = (int64_t)mu32;
    int32_t vterm   = (int32_t)Ex2 / (C >> 4); /* (Ex2<<4)/C  (valid: C%16==0) */
    int32_t var_hw  = vterm - mu32 * mu32;
    if (var_hw < 0) var_hw = 0;

    int32_t lut_idx = var_hw >> 8;
    if (lut_idx > 255) lut_idx = 255;

    int32_t inv_std = (int32_t)sh->inv_sqrt_lut[lut_idx];

    int32_t i;

    for (i = 0; i < C; i++) {

        int32_t g = (int32_t)sh->gamma_q[i] - sh->gamma_zp;
        int32_t b = (int32_t)sh->beta_q[i]  - sh->beta_zp;

        int32_t xi =
            ((int32_t)((int16_t)values[i] -
                       (int16_t)sh->global_zp))
            << (sh->alpha_factors[i] - min_alpha);

        /* K5 FIX: __muldi3 (int64×int32 multiply) is broken on this 32-bit
         * RISC-V toolchain, same issue as __divdi3 (already fixed above).
         * Use two widening multiplies (int32×int32 → int64) which emit
         * mul+mulh instructions instead of a library call.
         *   xm * inv_std: max ~33M (2048 * 16383) — fits in int32.
         *   xm_norm * g : widening → int64, no __muldi3.
         */
        int32_t xm      = xi - (int32_t)mu;
        int32_t xm_norm = (int32_t)((int64_t)xm * (int32_t)inv_std);
        int64_t temp    = (int64_t)xm_norm * g;

        int32_t y =
            (int32_t)((temp + (1 << 13)) >> 14) + b;

        /* ===== DEBUG channels 0-4, first vector only ===== */
        static int ch_dbg_done = 0;
        if (i < 5 && !ch_dbg_done) {
            bm_printf("DBG ch%d: val=%d xi=%d g=%d b=%d y=%d\n",
                      i, (int)values[i], xi, g, b, y);
        }
        if (i == 4) ch_dbg_done = 1;
        /* ===== END DEBUG ===== */

        if (y >  127) y =  127;
        else if (y < -128) y = -128;

        Y[i] = (int8_t)y;
    }
}

/****************************** SOFTWARE REFERENCE (NOX) ******************************/

void layernorm_nox(const SoleShared *sh,
                   const uint8_t    *values,
                   int8_t           *Y)
{
    int64_t Ex, Ex2;

    int8_t min_alpha =
        find_min_alpha(sh->alpha_factors, sh->num_channels);

    stage1(sh, values, &Ex, &Ex2, min_alpha);
    stage2_improved(sh, values, Ex, Ex2, min_alpha, Y);
}

/****************************** ACCELERATOR DRIVER (XLR) ******************************/

void layernorm_xlr(const SoleShared *sh,
                   const uint8_t    *values,
                   int8_t           *Y)
{
    // All pointers are already XMEM addresses — pass directly to HW registers
    *SOLE_SHARED_ADDR_REG = (unsigned int) sh;
    *SOLE_INPUT_ADDR_REG  = (unsigned int) values;
    *SOLE_OUTPUT_ADDR_REG = (unsigned int) Y;
    *SOLE_NUM_CH_REG      = (unsigned int) sh->num_channels;

    *SOLE_START_REG = 1;  // Trigger Start
    while (!*SOLE_DONE_REG) {
        // bm_printf("Pending SOLE_DONE_REG\n");  // Uncomment for debug
    }
}

/****************************** WRAPPER ******************************/

void layernorm(const SoleShared *sh,
               const uint8_t    *values,
               int8_t           *Y,
               boolean           use_accel)
{
    if (use_accel)
        layernorm_xlr(sh, values, Y);
    else
        layernorm_nox(sh, values, Y);
}

/****************************** MAIN ******************************/

int main()
{
    bm_printf("\nHELLO LAYERNORM REFERENCE\n");

    boolean use_accel = FALSE;
#ifdef XON
    use_accel = TRUE;
#endif
#ifdef XOFF
    use_accel = FALSE;
#endif

    char gen_test_per_run = FALSE;
#ifdef REGEN
    gen_test_per_run = TRUE;
#endif
    if (gen_test_per_run) {
        bm_printf("\nSystem call for generating test data\n");
        bm_sys_call("python3 app_src_dir/gen_sole_test.py");
    } else {
        bm_printf("\nNew test not generated, you may generate new test from runspace prompt by:\n");
        bm_printf("python3 app_src_dir/gen_sole_test.py\n");
    }

    // XMEM pointers — fixed addresses in XBOX memory space
    SoleShared *shared  = (SoleShared *)(SHARED_XMEM_ADDR);
    uint8_t    *cur_vec = (uint8_t *)   (INPUT_XMEM_ADDR);
    int8_t     *output  = (int8_t *)    (OUTPUT_XMEM_ADDR);

    int in_f  = bm_fopen_r("sole_test_in.txt");
    int out_f = bm_fopen_w("sole_test_out.txt");

    if (use_accel) bm_printf("\nAccelerator Enabled\n");
    else           bm_printf("\nAccelerator Disabled\n");

    /* ---------- Load SoleShared once into XMEM ---------- */

    bm_printf("\nLoading SoleShared into XMEM at 0x%08x\n", SHARED_XMEM_ADDR);

    int num_loaded = 0;
    bm_start_soc_load_hex_file(in_f, sizeof(SoleShared), (unsigned char *)shared);
    while (num_loaded == 0)
        num_loaded = bm_check_soc_load_hex_file();

    bm_printf("Loaded %d bytes (num_vectors=%d, channels=%d)\n",
              num_loaded, shared->num_vectors, shared->num_channels);

    /* ---------- Measure performance + process all vectors ---------- */

    int start_cycle, end_cycle;
    ENABLE_CYCLE_COUNT;
    RESET_CYCLE_COUNT;
    GET_CYCLE_COUNT_START(start_cycle);

    int32_t run_vectors = shared->num_vectors;
#ifdef DEBUG
    run_vectors = 5;
    bm_printf("DEBUG mode: running %d vectors only\n", run_vectors);
#endif

    int32_t v;
    for (v = 0; v < run_vectors; v++) {

        /* Load input vector into XMEM */
        num_loaded = 0;
        bm_start_soc_load_hex_file(in_f, MAX_CHANNELS, (unsigned char *)cur_vec);
        while (num_loaded == 0)
            num_loaded = bm_check_soc_load_hex_file();

        /* Compute LayerNorm — SW or HW path */
        layernorm(shared, cur_vec, output, use_accel);

        /* Write output vector from XMEM back to host */
        int num_dumped = 0;
        bm_start_soc_store_hex_file(out_f, MAX_CHANNELS, 32, (unsigned char *)output);
        while (num_dumped == 0)
            num_dumped = bm_check_soc_store_hex_file();
    }

    GET_CYCLE_COUNT_END(end_cycle);

    int cycle_cnt = end_cycle - start_cycle;
#ifndef XON
    cycle_cnt = cycle_cnt / 8;  // Factor single thread mode (other 7 threads unutilized)
#endif

    bm_printf("\n\n *** Total: %d K5 cycles | Per-vector avg: %d cycles (%d vectors) ***\n\n",
              cycle_cnt, cycle_cnt / run_vectors, run_vectors);

    bm_fclose(in_f);
    bm_fclose(out_f);

    bm_printf("\nCheck output vs golden reference\n");
    bm_sys_call("python3 app_src_dir/check_sole.py");

    bm_quit_app();  // flag to trigger execution termination
    return 0;
}
