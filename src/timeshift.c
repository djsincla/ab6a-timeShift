/*
 * timeshift — per-process clock shim for macOS.
 *
 * Injected with DYLD_INSERT_LIBRARIES. Uses dyld's __DATA,__interpose
 * mechanism, which rewrites call sites in every *other* loaded image but
 * not in the image that declares the interpose tuples. That means the
 * plain calls to gettimeofday(), mach_absolute_time() etc. below reach the
 * real implementations, and no trampoline/lookup dance is needed.
 *
 * Transform, applied in the nanosecond domain of whichever clock is read:
 *
 *     out = anchor + (in - anchor) * rate + offset
 *
 * where `anchor` is that clock's value when this library initialized. With
 * rate == 1.0 this is a pure offset; with rate != 1.0 the process's clock
 * runs fast or slow relative to the real one, diverging from the moment of
 * injection rather than from the epoch.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <mach/mach_time.h>


#define TS_EXPORT __attribute__((visibility("default")))

/* dyld interposing: a {replacement, replacee} pair in __DATA,__interpose. */
#define TS_INTERPOSE(_repl, _orig)                                            \
    __attribute__((used)) static const struct {                               \
        const void *repl;                                                     \
        const void *orig;                                                     \
    } _ts_interpose_##_orig __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&_repl, (const void *)(uintptr_t)&_orig      \
    }

#define TS_NS_PER_SEC 1000000000LL

/* ------------------------------------------------------------------ */
/* Shared control block (optional, for live adjustment)                */
/* ------------------------------------------------------------------ */

#define TS_MAGIC   0x54534846u /* 'TSHF' */
#define TS_VERSION 1u

/*
 * Laid out explicitly so the dylib and timeshift-ctl agree byte for byte.
 * offset/rate/flags are read on every clock call when a control file is
 * mapped, so an external writer can move the clock while the target runs.
 */
typedef struct {
    uint32_t          magic;
    uint32_t          version;
    _Atomic int64_t   offset_ns;
    _Atomic uint64_t  rate_bits; /* IEEE-754 bits of a double */
    _Atomic uint32_t  flags;     /* bit 0: also shift monotonic clocks */
    uint32_t          _pad;
    _Atomic uint64_t  generation; /* bumped by each writer, for humans */
    uint8_t           _reserved[24];
} ts_control_t;

#define TS_FLAG_MONOTONIC 0x1u

/* ------------------------------------------------------------------ */
/* State                                                               */
/* ------------------------------------------------------------------ */

#define TS_MAX_CLOCK 32
#define TS_CLOCK_PASSTHROUGH 0
#define TS_CLOCK_WALL        1
#define TS_CLOCK_MONO        2

static struct {
    double   rate;
    int64_t  offset_ns;
    int      shift_mono;
    int      debug;

    int64_t  anchor_wall_ns;
    int64_t  anchor_mach_abs_ns;
    int64_t  anchor_mach_cont_ns;
    int64_t  clock_anchor[TS_MAX_CLOCK];
    uint8_t  clock_kind[TS_MAX_CLOCK];


    mach_timebase_info_data_t tb;
    ts_control_t *ctl;
} g;

typedef struct {
    int64_t offset_ns;
    double  rate;
    int     mono;
} ts_params_t;

/*
 * Initialization cannot use pthread_once. ts_init calls into libSystem and
 * (in debug mode) stdio, and those call clock functions that are themselves
 * interposed; re-entering pthread_once from the thread already inside it is
 * an immediate abort ("recursively lock an os_once_t"). So: an explicit
 * state machine: any clock read taken while initialization is in flight —
 * whether it is this thread re-entering or another thread racing — passes
 * straight through unshifted.
 *
 * This deliberately uses no thread-local storage. The first interposed call
 * can arrive from inside libcorecrypto's initializer, before dyld has
 * bootstrapped TLS for this image, and touching a _Thread_local there aborts
 * the process in _tlv_bootstrap_error.
 */
#define TS_UNINIT 0
#define TS_BUSY   1
#define TS_READY  2

static _Atomic int g_state = TS_UNINIT;

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static inline int64_t ts_tv_to_ns(const struct timeval *tv)
{
    return (int64_t)tv->tv_sec * TS_NS_PER_SEC + (int64_t)tv->tv_usec * 1000LL;
}

static inline int64_t ts_ticks_to_ns(uint64_t ticks)
{
    return (int64_t)(((__uint128_t)ticks * g.tb.numer) / g.tb.denom);
}

static inline uint64_t ts_ns_to_ticks(int64_t ns)
{
    if (ns < 0)
        ns = 0;
    return (uint64_t)(((__uint128_t)ns * g.tb.denom) / g.tb.numer);
}

/* Read the live parameters: the control block wins if one is mapped. */
static inline ts_params_t ts_params(void)
{
    ts_params_t p = { g.offset_ns, g.rate, g.shift_mono };

    if (g.ctl != NULL && g.ctl->magic == TS_MAGIC) {
        uint64_t bits;
        p.offset_ns = atomic_load_explicit(&g.ctl->offset_ns, memory_order_relaxed);
        bits        = atomic_load_explicit(&g.ctl->rate_bits, memory_order_relaxed);
        memcpy(&p.rate, &bits, sizeof(p.rate));
        p.mono = (atomic_load_explicit(&g.ctl->flags, memory_order_relaxed) &
                  TS_FLAG_MONOTONIC) != 0;
        if (!(p.rate > 0.0)) /* also rejects NaN */
            p.rate = 1.0;
    }
    return p;
}

static inline int64_t ts_apply(int64_t ns, int64_t anchor, ts_params_t p)
{
    int64_t delta = ns - anchor;

    if (p.rate != 1.0)
        delta = (int64_t)llround((double)delta * p.rate);
    return anchor + delta + p.offset_ns;
}

/* ------------------------------------------------------------------ */
/* Debug output                                                        */
/* ------------------------------------------------------------------ */

/*
 * stdio is off limits here. The first interposed clock call can arrive from
 * libcorecrypto's initializer, and printing a %f there reaches __dtoa, which
 * calls malloc before the allocator is ready — an immediate segfault at
 * 0xdeaddeaddeaddead. So messages are formatted by hand into a stack buffer,
 * with no floating point, and handed to write(2).
 */
typedef struct {
    char   buf[320];
    size_t len;
} ts_msg_t;

static void ts_put(ts_msg_t *m, const char *s)
{
    while (*s != '\0' && m->len < sizeof(m->buf))
        m->buf[m->len++] = *s++;
}

static void ts_put_i64(ts_msg_t *m, int64_t v)
{
    char tmp[24];
    uint64_t u;
    int n = 0;

    if (v < 0) {
        ts_put(m, "-");
        u = (uint64_t)(-(v + 1)) + 1; /* avoids overflow at INT64_MIN */
    } else {
        u = (uint64_t)v;
    }
    do {
        tmp[n++] = (char)('0' + (u % 10));
        u /= 10;
    } while (u != 0);
    while (n-- > 0 && m->len < sizeof(m->buf))
        m->buf[m->len++] = tmp[n];
}

/* Print `scaled` as a decimal with `digits` fractional places. */
static void ts_put_fixed(ts_msg_t *m, int64_t scaled, int digits)
{
    char frac[20];
    int64_t div = 1, f;
    int i;

    for (i = 0; i < digits; i++)
        div *= 10;
    if (scaled < 0) {
        ts_put(m, "-");
        scaled = -scaled;
    }
    ts_put_i64(m, scaled / div);
    ts_put(m, ".");
    f = scaled % div;
    for (i = digits - 1; i >= 0; i--) {
        frac[i] = (char)('0' + (f % 10));
        f /= 10;
    }
    for (i = 0; i < digits && m->len < sizeof(m->buf); i++)
        m->buf[m->len++] = frac[i];
}

static void ts_flush(ts_msg_t *m)
{
    ts_put(m, "\n");
    (void)!write(STDERR_FILENO, m->buf, m->len);
}

static void ts_debug_str(const char *msg, const char *arg)
{
    ts_msg_t m;

    m.len = 0;
    ts_put(&m, msg);
    if (arg != NULL)
        ts_put(&m, arg);
    ts_flush(&m);
}

/* ------------------------------------------------------------------ */
/* Initialization                                                      */
/* ------------------------------------------------------------------ */

static void ts_map_control(const char *path)
{
    int fd;
    struct stat st;
    void *map;

    fd = open(path, O_RDWR);
    if (fd < 0) {
        if (g.debug)
            ts_debug_str("[timeshift] cannot open control file ", path);
        return;
    }
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(ts_control_t)) {
        if (g.debug)
            ts_debug_str("[timeshift] control file too small: ", path);
        close(fd);
        return;
    }

    map = mmap(NULL, sizeof(ts_control_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd); /* the mapping keeps the file alive */
    if (map == MAP_FAILED) {
        if (g.debug)
            ts_debug_str("[timeshift] mmap failed: ", path);
        return;
    }

    if (((ts_control_t *)map)->magic != TS_MAGIC ||
        ((ts_control_t *)map)->version != TS_VERSION) {
        if (g.debug)
            ts_debug_str("[timeshift] not a valid control file: ", path);
        munmap(map, sizeof(ts_control_t));
        return;
    }
    g.ctl = (ts_control_t *)map;
}

static void ts_anchor_clock(clockid_t id, uint8_t kind)
{
    if ((unsigned)id >= TS_MAX_CLOCK)
        return;
    g.clock_kind[id] = kind;
    if (kind == TS_CLOCK_MONO)
        g.clock_anchor[id] = (int64_t)clock_gettime_nsec_np(id);
}

static void ts_init(void)
{
    struct timeval tv;
    const char *env;

    g.rate       = 1.0;
    g.offset_ns  = 0;
    g.shift_mono = 0;

    env = getenv("TIMESHIFT_DEBUG");
    g.debug = (env != NULL && *env != '\0' && strcmp(env, "0") != 0);

    mach_timebase_info(&g.tb);
    if (g.tb.numer == 0 || g.tb.denom == 0) {
        g.tb.numer = 1;
        g.tb.denom = 1;
    }

    /* Anchors first, so every clock's zero point is the same instant. */
    if (gettimeofday(&tv, NULL) == 0)
        g.anchor_wall_ns = ts_tv_to_ns(&tv);
    g.anchor_mach_abs_ns  = ts_ticks_to_ns(mach_absolute_time());
    g.anchor_mach_cont_ns = ts_ticks_to_ns(mach_continuous_time());

    ts_anchor_clock(CLOCK_REALTIME, TS_CLOCK_WALL);
    ts_anchor_clock(CLOCK_MONOTONIC, TS_CLOCK_MONO);
    ts_anchor_clock(CLOCK_MONOTONIC_RAW, TS_CLOCK_MONO);
    ts_anchor_clock(CLOCK_MONOTONIC_RAW_APPROX, TS_CLOCK_MONO);
    ts_anchor_clock(CLOCK_UPTIME_RAW, TS_CLOCK_MONO);
    ts_anchor_clock(CLOCK_UPTIME_RAW_APPROX, TS_CLOCK_MONO);
    /* CPU-time clocks measure consumption, not time of day: left alone. */

    if ((env = getenv("TIMESHIFT_RATE")) != NULL) {
        double r = strtod(env, NULL);
        if (r > 0.0)
            g.rate = r;
    }

    /* Offset sources, lowest precedence first. */
    if ((env = getenv("TIMESHIFT_OFFSET_MS")) != NULL)
        g.offset_ns = (int64_t)llround(strtod(env, NULL) * 1e6);
    if ((env = getenv("TIMESHIFT_OFFSET_NS")) != NULL)
        g.offset_ns = (int64_t)strtoll(env, NULL, 10);
    if ((env = getenv("TIMESHIFT_AT")) != NULL) {
        /* Absolute target: pin the clock so that "now" reads as TIMESHIFT_AT. */
        double target_s = strtod(env, NULL);
        g.offset_ns = (int64_t)llround(target_s * 1e9) - g.anchor_wall_ns;
    }

    if ((env = getenv("TIMESHIFT_MONOTONIC")) != NULL)
        g.shift_mono = (*env != '\0' && strcmp(env, "0") != 0);

    if ((env = getenv("TIMESHIFT_CONTROL")) != NULL && *env != '\0')
        ts_map_control(env);

    if (g.debug) {
        ts_params_t p = ts_params();
        ts_msg_t m;

        m.len = 0;
        ts_put(&m, "[timeshift] pid ");
        ts_put_i64(&m, (int64_t)getpid());
        ts_put(&m, " armed: offset ");
        ts_put_fixed(&m, p.offset_ns, 9);
        ts_put(&m, " s, rate ");
        ts_put_fixed(&m, (int64_t)(p.rate * 1e9), 9);
        ts_put(&m, ", monotonic ");
        ts_put(&m, p.mono ? "shifted" : "untouched");
        if (g.ctl != NULL)
            ts_put(&m, ", live control mapped");
        ts_flush(&m);
    }
}

/*
 * Returns non-zero when the transform may be applied. Anything called during
 * initialization — including the clock reads libSystem makes on our behalf —
 * gets a zero and therefore the untouched value.
 */
static int ts_ready(void)
{
    int expected = TS_UNINIT;
    int state = atomic_load_explicit(&g_state, memory_order_acquire);

    if (state == TS_READY)
        return 1;
    if (state == TS_BUSY)
        return 0; /* re-entered from inside ts_init, or another thread got there first */

    if (!atomic_compare_exchange_strong_explicit(&g_state, &expected, TS_BUSY,
                                                 memory_order_acq_rel,
                                                 memory_order_acquire))
        return 0; /* lost the race; don't block the winner */

    ts_init();
    atomic_store_explicit(&g_state, TS_READY, memory_order_release);
    return 1;
}

__attribute__((constructor)) static void ts_ctor(void)
{
    ts_ready();
}

/* ------------------------------------------------------------------ */
/* Interposed entry points                                             */
/* ------------------------------------------------------------------ */

static int ts_gettimeofday(struct timeval *restrict tp, void *restrict tzp)
{
    int rc = gettimeofday(tp, tzp);
    int64_t ns;

    if (rc != 0 || tp == NULL || !ts_ready())
        return rc;

    ns = ts_apply(ts_tv_to_ns(tp), g.anchor_wall_ns, ts_params());
    tp->tv_sec  = (time_t)(ns / TS_NS_PER_SEC);
    tp->tv_usec = (suseconds_t)((ns % TS_NS_PER_SEC) / 1000LL);
    return rc;
}
TS_INTERPOSE(ts_gettimeofday, gettimeofday);

static int ts_clock_gettime(clockid_t clk_id, struct timespec *tp)
{
    int rc = clock_gettime(clk_id, tp);
    ts_params_t p;
    int64_t ns;
    uint8_t kind;

    if (rc != 0 || tp == NULL || (unsigned)clk_id >= TS_MAX_CLOCK || !ts_ready())
        return rc;

    kind = g.clock_kind[clk_id];
    if (kind == TS_CLOCK_PASSTHROUGH)
        return rc;

    p = ts_params();
    if (kind == TS_CLOCK_MONO && !p.mono)
        return rc;

    ns = (int64_t)tp->tv_sec * TS_NS_PER_SEC + (int64_t)tp->tv_nsec;
    ns = ts_apply(ns,
                  kind == TS_CLOCK_WALL ? g.anchor_wall_ns : g.clock_anchor[clk_id],
                  p);
    if (ns < 0)
        ns = 0;
    tp->tv_sec  = (time_t)(ns / TS_NS_PER_SEC);
    tp->tv_nsec = (long)(ns % TS_NS_PER_SEC);
    return rc;
}
TS_INTERPOSE(ts_clock_gettime, clock_gettime);

static uint64_t ts_clock_gettime_nsec_np(clockid_t clk_id)
{
    uint64_t v = clock_gettime_nsec_np(clk_id);
    ts_params_t p;
    uint8_t kind;
    int64_t ns;

    /* 0 means failure for this API, so it is never transformed. */
    if (v == 0 || (unsigned)clk_id >= TS_MAX_CLOCK || !ts_ready())
        return v;

    kind = g.clock_kind[clk_id];
    if (kind == TS_CLOCK_PASSTHROUGH)
        return v;

    p = ts_params();
    if (kind == TS_CLOCK_MONO && !p.mono)
        return v;

    ns = ts_apply((int64_t)v,
                  kind == TS_CLOCK_WALL ? g.anchor_wall_ns : g.clock_anchor[clk_id],
                  p);
    return ns < 0 ? 0 : (uint64_t)ns;
}
TS_INTERPOSE(ts_clock_gettime_nsec_np, clock_gettime_nsec_np);

/*
 * time() is served from gettimeofday rather than the real time() so that a
 * sub-second offset floors to the correct second instead of being lost.
 */
static time_t ts_time(time_t *tloc)
{
    struct timeval tv;
    int64_t ns;
    time_t out;

    if (gettimeofday(&tv, NULL) != 0 || !ts_ready())
        return time(tloc);

    ns  = ts_apply(ts_tv_to_ns(&tv), g.anchor_wall_ns, ts_params());
    out = (time_t)(ns / TS_NS_PER_SEC);
    if (tloc != NULL)
        *tloc = out;
    return out;
}
TS_INTERPOSE(ts_time, time);

/* --- monotonic family: only touched when explicitly enabled --------- */

static inline uint64_t ts_shift_ticks(uint64_t ticks, int64_t anchor)
{
    ts_params_t p;

    if (!ts_ready())
        return ticks;
    p = ts_params();
    if (!p.mono)
        return ticks;
    return ts_ns_to_ticks(ts_apply(ts_ticks_to_ns(ticks), anchor, p));
}

static uint64_t ts_mach_absolute_time(void)
{
    return ts_shift_ticks(mach_absolute_time(), g.anchor_mach_abs_ns);
}
TS_INTERPOSE(ts_mach_absolute_time, mach_absolute_time);

static uint64_t ts_mach_approximate_time(void)
{
    return ts_shift_ticks(mach_approximate_time(), g.anchor_mach_abs_ns);
}
TS_INTERPOSE(ts_mach_approximate_time, mach_approximate_time);

static uint64_t ts_mach_continuous_time(void)
{
    return ts_shift_ticks(mach_continuous_time(), g.anchor_mach_cont_ns);
}
TS_INTERPOSE(ts_mach_continuous_time, mach_continuous_time);

static uint64_t ts_mach_continuous_approximate_time(void)
{
    return ts_shift_ticks(mach_continuous_approximate_time(), g.anchor_mach_cont_ns);
}
TS_INTERPOSE(ts_mach_continuous_approximate_time, mach_continuous_approximate_time);


/* ------------------------------------------------------------------ */
/* Introspection, for the probe                                        */
/* ------------------------------------------------------------------ */

TS_EXPORT int timeshift_loaded(void)
{
    return TS_VERSION;
}

TS_EXPORT void timeshift_current(int64_t *offset_ns, double *rate, int *mono)
{
    ts_params_t p;

    ts_ready();
    p = ts_params();
    if (offset_ns != NULL)
        *offset_ns = p.offset_ns;
    if (rate != NULL)
        *rate = p.rate;
    if (mono != NULL)
        *mono = p.mono;
}
