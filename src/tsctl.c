/*
 * timeshift-ctl — create and update a timeshift control file.
 *
 * The control file is a fixed 64-byte block that shimmed processes mmap and
 * re-read on every clock call, so writing to it moves the clock of every
 * running process sharing that file.
 *
 *   timeshift-ctl init   <file> [--offset DUR] [--rate R] [--monotonic]
 *   timeshift-ctl set    <file> [--offset DUR] [--rate R] [--monotonic 0|1]
 *   timeshift-ctl nudge  <file> --offset DUR       (relative to current)
 *   timeshift-ctl show   <file>
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#define TS_MAGIC   0x54534846u
#define TS_VERSION 1u
#define TS_FLAG_MONOTONIC 0x1u

typedef struct {
    uint32_t          magic;
    uint32_t          version;
    _Atomic int64_t   offset_ns;
    _Atomic uint64_t  rate_bits;
    _Atomic uint32_t  flags;
    uint32_t          _pad;
    _Atomic uint64_t  generation;
    uint8_t           _reserved[24];
} ts_control_t;

static void usage(void)
{
    fputs("usage: timeshift-ctl init|set|nudge|show <file> [options]\n"
          "  --offset DUR     offset, e.g. -5s, 100ms, 0.1s, 250us, 1500000ns\n"
          "                   (bare numbers are nanoseconds; nudge adds to current)\n"
          "  --rate R         clock rate multiplier (> 0)\n"
          "  --monotonic 0|1  also shift mach_absolute_time / CLOCK_MONOTONIC\n",
          stderr);
    exit(2);
}

/* "-5s", "0.1s", "100ms", "250us", "1500ns", or a bare nanosecond count. */
static int64_t parse_duration(const char *spec)
{
    char *end;
    double value = strtod(spec, &end);
    double scale;

    if (end == spec) {
        fprintf(stderr, "cannot parse duration '%s'\n", spec);
        exit(2);
    }
    while (*end == ' ')
        end++;

    if (*end == '\0' || strcmp(end, "ns") == 0)      scale = 1.0;
    else if (strcmp(end, "us") == 0)                 scale = 1e3;
    else if (strcmp(end, "ms") == 0)                 scale = 1e6;
    else if (strcmp(end, "s") == 0)                  scale = 1e9;
    else if (strcmp(end, "m") == 0)                  scale = 60e9;
    else if (strcmp(end, "h") == 0)                  scale = 3600e9;
    else if (strcmp(end, "d") == 0)                  scale = 86400e9;
    else {
        fprintf(stderr, "unknown duration unit '%s'\n", end);
        exit(2);
    }
    return (int64_t)llround(value * scale);
}

static double bits_to_double(uint64_t bits)
{
    double d;
    memcpy(&d, &bits, sizeof(d));
    return d;
}

static uint64_t double_to_bits(double d)
{
    uint64_t bits;
    memcpy(&bits, &d, sizeof(bits));
    return bits;
}

static ts_control_t *map_control(const char *path, int create)
{
    int fd;
    void *map;

    fd = open(path, create ? (O_RDWR | O_CREAT) : O_RDWR, 0644);
    if (fd < 0) {
        perror(path);
        exit(1);
    }
    if (create && ftruncate(fd, (off_t)sizeof(ts_control_t)) != 0) {
        perror("ftruncate");
        exit(1);
    }

    map = mmap(NULL, sizeof(ts_control_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    return (ts_control_t *)map;
}

int main(int argc, char **argv)
{
    const char *cmd, *path;
    ts_control_t *c;
    int have_offset = 0, have_rate = 0, have_mono = 0, i;
    int64_t offset = 0;
    double rate = 1.0;
    int mono = 0;

    if (argc < 3)
        usage();
    cmd  = argv[1];
    path = argv[2];

    for (i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--offset") == 0 && i + 1 < argc) {
            offset = parse_duration(argv[++i]);
            have_offset = 1;
        } else if (strcmp(argv[i], "--rate") == 0 && i + 1 < argc) {
            rate = strtod(argv[++i], NULL);
            have_rate = 1;
        } else if (strcmp(argv[i], "--monotonic") == 0) {
            mono = (i + 1 < argc && argv[i + 1][0] != '-') ? atoi(argv[++i]) : 1;
            have_mono = 1;
        } else {
            usage();
        }
    }

    if (strcmp(cmd, "init") == 0) {
        c = map_control(path, 1);
        c->magic   = TS_MAGIC;
        c->version = TS_VERSION;
        atomic_store(&c->offset_ns, offset);
        atomic_store(&c->rate_bits, double_to_bits(have_rate ? rate : 1.0));
        atomic_store(&c->flags, mono ? TS_FLAG_MONOTONIC : 0u);
        atomic_store(&c->generation, 1);
    } else {
        c = map_control(path, 0);
        if (c->magic != TS_MAGIC || c->version != TS_VERSION) {
            fprintf(stderr, "%s: not a v%u timeshift control file\n", path, TS_VERSION);
            return 1;
        }

        if (strcmp(cmd, "set") == 0) {
            if (have_offset)
                atomic_store(&c->offset_ns, offset);
            if (have_rate) {
                if (!(rate > 0.0)) {
                    fputs("rate must be > 0\n", stderr);
                    return 1;
                }
                atomic_store(&c->rate_bits, double_to_bits(rate));
            }
            if (have_mono)
                atomic_store(&c->flags, mono ? TS_FLAG_MONOTONIC : 0u);
            atomic_fetch_add(&c->generation, 1);
        } else if (strcmp(cmd, "nudge") == 0) {
            if (!have_offset) {
                fputs("nudge requires --offset\n", stderr);
                return 1;
            }
            atomic_fetch_add(&c->offset_ns, offset);
            atomic_fetch_add(&c->generation, 1);
        } else if (strcmp(cmd, "show") != 0) {
            usage();
        }
    }

    printf("%s: offset %+.9f s  rate %.9f  monotonic %s  gen %llu\n",
           path,
           (double)atomic_load(&c->offset_ns) / 1e9,
           bits_to_double(atomic_load(&c->rate_bits)),
           (atomic_load(&c->flags) & TS_FLAG_MONOTONIC) ? "on" : "off",
           (unsigned long long)atomic_load(&c->generation));

    msync(c, sizeof(*c), MS_SYNC);
    return 0;
}
