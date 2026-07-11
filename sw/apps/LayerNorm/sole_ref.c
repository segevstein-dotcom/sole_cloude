#include <k5_libs.h>
#include <stdint.h>

#define MAX_CHANNELS 384
#define MAX_VECTORS  197

#define SHARED_XMEM_ADDR  0x40000000
#define INPUT_XMEM_ADDR   0x400006A0
#define OUTPUT_XMEM_ADDR  0x40000820

#define SM_REGS_BASE_IDX 0

#define SOLE_SHARED_ADDR_REG_IDX  (SM_REGS_BASE_IDX + 0)
#define SOLE_INPUT_ADDR_REG_IDX   (SM_REGS_BASE_IDX + 1)
#define SOLE_OUTPUT_ADDR_REG_IDX  (SM_REGS_BASE_IDX + 2)
#define SOLE_NUM_CH_REG_IDX       (SM_REGS_BASE_IDX + 3)
#define SOLE_START_REG_IDX        (SM_REGS_BASE_IDX + 4)
#define SOLE_DONE_REG_IDX         (SM_REGS_BASE_IDX + 5)

#define SOLE_SHARED_ADDR_REG  ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + 4 * SOLE_SHARED_ADDR_REG_IDX))
#define SOLE_INPUT_ADDR_REG   ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + 4 * SOLE_INPUT_ADDR_REG_IDX))
#define SOLE_OUTPUT_ADDR_REG  ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + 4 * SOLE_OUTPUT_ADDR_REG_IDX))
#define SOLE_NUM_CH_REG       ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + 4 * SOLE_NUM_CH_REG_IDX))
#define SOLE_START_REG        ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + 4 * SOLE_START_REG_IDX))
#define SOLE_DONE_REG         ((volatile unsigned int *)(XBOX_REGS_BASE_ADDR + 4 * SOLE_DONE_REG_IDX))

/********* for batching vectors ***************/

#define BATCH_VECTORS 80
#define VECTOR_BYTES  MAX_CHANNELS

#define INPUT_BATCH_XMEM_ADDR   0x400006A0
#define OUTPUT_BATCH_XMEM_ADDR  0x40007EA0

/******************************************/

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

static const uint16_t SQUARE_LUT[16] = {
    0, 1, 4, 9, 16, 25, 36, 49,
    64, 81, 100, 121, 144, 169, 196, 225
};

static unsigned int g_reg_cycles     = 0;
static unsigned int g_poll_cycles    = 0;
static unsigned int g_compute_cycles = 0;  /* SW path: find_min_alpha + stage1 + stage2 */
static unsigned int g_load_cycles    = 0;
static unsigned int g_store_cycles   = 0;
static unsigned int g_printf_cycles  = 0;

/* Software reference path */
static void dynamic_compress(uint8_t x, uint8_t *c, uint8_t *s)
{
    if (x < 64) {
        *c = (x + 2) >> 2;
        *s = 0;
    } else {
        *c = (x + 8) >> 4;
        *s = 1;
    }

    if (*c > 15)
        *c = 15;
}

static int8_t find_min_alpha(const int8_t *a, int32_t n)
{
    int8_t m = 127;

    for (int32_t i = 0; i < n; i++) {
        if (a[i] < m)
            m = a[i];
    }

    return m;
}

static void stage1(const SoleShared *sh,
                   const uint8_t *values,
                   int64_t *ex,
                   int64_t *ex2,
                   int8_t min_alpha)
{
    *ex  = 0;
    *ex2 = 0;

    for (int32_t i = 0; i < sh->num_channels; i++) {
        int16_t xi = (int16_t)values[i] - (int16_t)sh->global_zp;
        uint8_t abs_x = (xi < 0) ? -xi : xi;

        uint8_t c, s;
        dynamic_compress(abs_x, &c, &s);

        uint32_t xc2 = (uint32_t)SQUARE_LUT[c] << (4 * s);
        int32_t rel_shift = sh->alpha_factors[i] - min_alpha;

        *ex  += (int64_t)((int32_t)xi << rel_shift);
        *ex2 += (int64_t)(xc2 << (2 * rel_shift));
    }
}

static void stage2_improved(const SoleShared *sh,
                            const uint8_t *values,
                            int64_t ex,
                            int64_t ex2,
                            int8_t min_alpha,
                            int8_t *y_out)
{
    int32_t c = sh->num_channels;
    int32_t mu32 = (int32_t)ex / c;
    int64_t mu = (int64_t)mu32;

    int32_t vterm = (int32_t)ex2 / (c >> 4);
    int32_t var_hw = vterm - mu32 * mu32;

    if (var_hw < 0)
        var_hw = 0;

    int32_t lut_idx = var_hw >> 8;
    if (lut_idx > 255)
        lut_idx = 255;

    int32_t inv_std = (int32_t)sh->inv_sqrt_lut[lut_idx];

    for (int32_t i = 0; i < c; i++) {
        int32_t g = (int32_t)sh->gamma_q[i] - sh->gamma_zp;
        int32_t b = (int32_t)sh->beta_q[i]  - sh->beta_zp;

        int32_t xi =
            ((int32_t)((int16_t)values[i] - (int16_t)sh->global_zp))
            << (sh->alpha_factors[i] - min_alpha);

        int32_t xm = xi - (int32_t)mu;
        int32_t xm_norm = (int32_t)((int64_t)xm * inv_std);
        int64_t temp = (int64_t)xm_norm * g;

        int32_t y = (int32_t)((temp + (1 << 13)) >> 14) + b;

        if (y > 127)
            y = 127;
        else if (y < -128)
            y = -128;

        y_out[i] = (int8_t)y;
    }
}

void layernorm_nox(const SoleShared *sh,
                   const uint8_t *values,
                   int8_t *y_out)
{
    unsigned int _t0, _t1;
    int64_t ex, ex2;

    GET_CYCLE_COUNT_START(_t0);
    int8_t min_alpha = find_min_alpha(sh->alpha_factors, sh->num_channels);
    stage1(sh, values, &ex, &ex2, min_alpha);
    stage2_improved(sh, values, ex, ex2, min_alpha, y_out);
    GET_CYCLE_COUNT_END(_t1);
    g_compute_cycles += _t1 - _t0;
}

/* Accelerator path */
void layernorm_xlr(const SoleShared *sh,
                   const uint8_t *values,
                   int8_t *y_out)
{
    unsigned int _t0, _t1, _t2;

    GET_CYCLE_COUNT_START(_t0);
    *SOLE_SHARED_ADDR_REG = (unsigned int)sh;
    *SOLE_INPUT_ADDR_REG  = (unsigned int)values;
    *SOLE_OUTPUT_ADDR_REG = (unsigned int)y_out;
    *SOLE_NUM_CH_REG      = (unsigned int)sh->num_channels;
    *SOLE_START_REG = 1;
    GET_CYCLE_COUNT_END(_t1);
    g_reg_cycles += _t1 - _t0;

    int wait_cnt = 0;
    while (!*SOLE_DONE_REG) {
        wait_cnt++;

        if (wait_cnt > 1000000) {
            bm_printf("ERROR: timeout waiting for accelerator DONE\n");
            break;
        }
    }
    GET_CYCLE_COUNT_END(_t2);
    g_poll_cycles += _t2 - _t1;
}

void layernorm(const SoleShared *sh,
               const uint8_t *values,
               int8_t *y_out,
               boolean use_accel)
{
    if (use_accel)
        layernorm_xlr(sh, values, y_out);
    else
        layernorm_nox(sh, values, y_out);
}

int main()
{
    bm_printf("\nHELLO LAYERNORM REFERENCE\n");

    boolean use_accel = FALSE;
    int32_t run_vectors;

#ifdef XON
    use_accel = TRUE;
#endif

#ifdef XON_DEBUG
    use_accel = TRUE;
#endif

#ifdef DEBUG
    use_accel = FALSE;
#endif

    SoleShared *shared = (SoleShared *)SHARED_XMEM_ADDR;
    
    int in_f  = bm_fopen_r("sole_test_in.txt");
    int out_f = bm_fopen_w("sole_test_out.txt");

    bm_printf("\nLoading SoleShared into XMEM at 0x%08x\n", SHARED_XMEM_ADDR);

    int num_loaded = 0;
    bm_start_soc_load_hex_file(in_f, sizeof(SoleShared), (unsigned char *)shared);

    while (num_loaded == 0)
        num_loaded = bm_check_soc_load_hex_file();

    bm_printf("Loaded %d bytes (num_vectors=%d, channels=%d)\n",
              num_loaded, shared->num_vectors, shared->num_channels);

    run_vectors = shared->num_vectors;

#ifdef XON_DEBUG
    run_vectors = 100;
#endif

#ifdef DEBUG
    run_vectors = 100;
#endif

    if (use_accel)
        bm_printf("\nAccelerator Enabled\n");
    else
        bm_printf("\nAccelerator Disabled\n");

    bm_printf("Running %d vectors\n", run_vectors);

    ENABLE_CYCLE_COUNT;
    RESET_CYCLE_COUNT;
    GET_CYCLE_COUNT_START(start_cycle);

    // uint8_t *cur_vec = (uint8_t *)INPUT_XMEM_ADDR;
    // int8_t *output   = (int8_t *)OUTPUT_XMEM_ADDR;
    // for (int32_t v = 0; v < run_vectors; v++) {
    //     num_loaded = 0;
    //     bm_start_soc_load_hex_file(in_f, MAX_CHANNELS, (unsigned char *)cur_vec);

    //     while (num_loaded == 0)
    //         num_loaded = bm_check_soc_load_hex_file();

    //     layernorm(shared, cur_vec, output, use_accel);

    //     int num_dumped = 0;
    //     bm_start_soc_store_hex_file(out_f, MAX_CHANNELS, 32, (unsigned char *)output);

    //     while (num_dumped == 0)
    //         num_dumped = bm_check_soc_store_hex_file();
    // }

    uint8_t *input_batch = (uint8_t *)INPUT_BATCH_XMEM_ADDR;
    int8_t  *output_batch = (int8_t *)OUTPUT_BATCH_XMEM_ADDR;

    for (int32_t base_v = 0; base_v < run_vectors; base_v += BATCH_VECTORS) {

        int32_t batch = BATCH_VECTORS;

        if (base_v + batch > run_vectors)
            batch = run_vectors - base_v;

        num_loaded = 0;

        unsigned int _bt0, _bt1;

        GET_CYCLE_COUNT_START(_bt0);
        bm_printf("BATCH START base=%d batch=%d bytes=%d\n",base_v, batch, batch * VECTOR_BYTES);
        GET_CYCLE_COUNT_END(_bt1);
        g_printf_cycles += _bt1 - _bt0;

        GET_CYCLE_COUNT_START(_bt0);
        bm_start_soc_load_hex_file(
            in_f,
            batch * VECTOR_BYTES,
            (unsigned char *)input_batch
        );
        while (num_loaded == 0)
            num_loaded = bm_check_soc_load_hex_file();
        GET_CYCLE_COUNT_END(_bt1);
        g_load_cycles += _bt1 - _bt0;

        for (int32_t i = 0; i < batch; i++) {

            uint8_t *cur_vec_b =
                input_batch + i * VECTOR_BYTES;

            int8_t *cur_out_b =
                output_batch + i * VECTOR_BYTES;

            layernorm(shared, cur_vec_b, cur_out_b, use_accel);
        }

        int num_dumped = 0;

        GET_CYCLE_COUNT_START(_bt0);
        bm_start_soc_store_hex_file(
            out_f,
            batch * VECTOR_BYTES,
            32,
            (unsigned char *)output_batch
        );
        while (num_dumped == 0)
            num_dumped = bm_check_soc_store_hex_file();
        GET_CYCLE_COUNT_END(_bt1);
        g_store_cycles += _bt1 - _bt0;

        GET_CYCLE_COUNT_START(_bt0);
        bm_printf("BATCH DONE base=%d\n", base_v);
        GET_CYCLE_COUNT_END(_bt1);
        g_printf_cycles += _bt1 - _bt0;

    }



    GET_CYCLE_COUNT_END(end_cycle);

    int cycle_cnt = end_cycle - start_cycle;

#ifndef XON
#ifndef XON_DEBUG
    // cycle_cnt = cycle_cnt / 8;  // Disabled: K5 8-thread normalization (see xmemcpy_ref.c:129)
#endif
#endif

    bm_printf("\n\n *** Total: %d K5 cycles | Per-vector avg: %d cycles (%d vectors) ***\n\n",
              cycle_cnt, cycle_cnt / run_vectors, run_vectors);

    int g_misc_cycles = cycle_cnt - (int)g_reg_cycles - (int)g_poll_cycles
                        - (int)g_compute_cycles
                        - (int)g_load_cycles - (int)g_store_cycles - (int)g_printf_cycles;
    bm_printf(" Cycle breakdown (%d vectors):\n", run_vectors);
    bm_printf("   Reg writes  : %d total | %d/vec\n", g_reg_cycles,     (int)g_reg_cycles     / run_vectors);
    bm_printf("   Poll DONE   : %d total | %d/vec\n", g_poll_cycles,    (int)g_poll_cycles    / run_vectors);
    bm_printf("   Compute(SW) : %d total | %d/vec\n", g_compute_cycles, (int)g_compute_cycles / run_vectors);
    bm_printf("   Batch load  : %d total | %d/vec\n", g_load_cycles,    (int)g_load_cycles    / run_vectors);
    bm_printf("   Batch store : %d total | %d/vec\n", g_store_cycles,   (int)g_store_cycles   / run_vectors);
    bm_printf("   Printf      : %d total | %d/vec\n", g_printf_cycles,  (int)g_printf_cycles  / run_vectors);
    bm_printf("   Misc/other  : %d total | %d/vec\n", g_misc_cycles,    g_misc_cycles         / run_vectors);

    bm_fclose(in_f);
    bm_fclose(out_f);

    bm_printf("\nCheck output vs golden reference\n");
    bm_sys_call("python3 app_src_dir/check_sole.py");

    bm_quit_app();
    return 0;
}