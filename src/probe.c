/*
 * timeshift-probe — read every clock the shim interposes and report what
 * each one says, so you can confirm the injection actually took and that no
 * entry point was missed.
 *
 *   timeshift-probe            one sample
 *   timeshift-probe --watch N  sample every N seconds until interrupted
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/time.h>
#include <time.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

#define NS_PER_SEC 1000000000LL

static int64_t ticks_to_ns(uint64_t ticks)
{
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0)
        mach_timebase_info(&tb);
    return (int64_t)(((__uint128_t)ticks * tb.numer) / tb.denom);
}

static void print_wall(const char *label, int64_t ns, int64_t reference)
{
    time_t secs = (time_t)(ns / NS_PER_SEC);
    struct tm tm;
    char stamp[64];

    gmtime_r(&secs, &tm);
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);

    printf("  %-32s %s.%09lld UTC", label, stamp,
           (long long)(ns % NS_PER_SEC));
    if (reference != 0)
        printf("   (%+.6f s vs real)", (double)(ns - reference) / 1e9);
    putchar('\n');
}

static void sample(void)
{
    struct timeval tv;
    struct timespec ts;
    uint64_t nsec_np, mach_abs, mach_cont;
    time_t t;
    CFAbsoluteTime cf;
    int64_t real_ns;

    /*
     * gettimeofday is the reference the other wall clocks are compared
     * against. When the shim is loaded it is shifted too, so agreement
     * between the rows is what proves no entry point was missed; compare
     * against an unshimmed run to see the absolute offset.
     */
    gettimeofday(&tv, NULL);
    real_ns = (int64_t)tv.tv_sec * NS_PER_SEC + (int64_t)tv.tv_usec * 1000LL;

    clock_gettime(CLOCK_REALTIME, &ts);
    nsec_np   = clock_gettime_nsec_np(CLOCK_REALTIME);
    t         = time(NULL);
    mach_abs  = mach_absolute_time();
    mach_cont = mach_continuous_time();
    cf        = CFAbsoluteTimeGetCurrent();

    puts("wall clocks (all should agree to within a few microseconds):");
    print_wall("gettimeofday", real_ns, 0);
    print_wall("clock_gettime(REALTIME)",
               (int64_t)ts.tv_sec * NS_PER_SEC + ts.tv_nsec, real_ns);
    print_wall("clock_gettime_nsec_np(REALTIME)", (int64_t)nsec_np, real_ns);
    print_wall("time()", (int64_t)t * NS_PER_SEC, real_ns);
    print_wall("CFAbsoluteTimeGetCurrent",
               (int64_t)((cf + kCFAbsoluteTimeIntervalSince1970) * 1e9), real_ns);

    printf("monotonic clocks:\n");
    printf("  %-32s %.9f s\n", "mach_absolute_time",
           (double)ticks_to_ns(mach_abs) / 1e9);
    printf("  %-32s %.9f s\n", "mach_continuous_time",
           (double)ticks_to_ns(mach_cont) / 1e9);
    clock_gettime(CLOCK_MONOTONIC, &ts);
    printf("  %-32s %.9f s\n", "clock_gettime(MONOTONIC)",
           (double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
    clock_gettime(CLOCK_UPTIME_RAW, &ts);
    printf("  %-32s %.9f s\n", "clock_gettime(UPTIME_RAW)",
           (double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
}

int main(int argc, char **argv)
{
    int (*loaded)(void);
    void (*current)(int64_t *, double *, int *);
    double interval = 0.0;
    int epoch_mode = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--watch") == 0 && i + 1 < argc)
            interval = strtod(argv[++i], NULL);
        else if (strcmp(argv[i], "--epoch") == 0)
            epoch_mode = 1;
        else {
            fputs("usage: timeshift-probe [--watch SECONDS] [--epoch]\n", stderr);
            return 2;
        }
    }

    /* Machine-readable: this process's wall clock in epoch nanoseconds. */
    if (epoch_mode) {
        setvbuf(stdout, NULL, _IOLBF, 0);
        for (;;) {
            struct timeval tv;
            gettimeofday(&tv, NULL);
            printf("%lld\n", (long long)tv.tv_sec * NS_PER_SEC +
                              (long long)tv.tv_usec * 1000LL);
            if (interval <= 0.0)
                break;
            usleep((useconds_t)(interval * 1e6));
        }
        return 0;
    }

    loaded  = (int (*)(void))dlsym(RTLD_DEFAULT, "timeshift_loaded");
    current = (void (*)(int64_t *, double *, int *))dlsym(RTLD_DEFAULT, "timeshift_current");

    if (loaded != NULL && current != NULL) {
        int64_t offset_ns;
        double rate;
        int mono;

        current(&offset_ns, &rate, &mono);
        printf("shim: LOADED (v%d)  offset %+.9f s  rate %.9f  monotonic %s\n\n",
               loaded(), (double)offset_ns / 1e9, rate, mono ? "shifted" : "untouched");
    } else {
        printf("shim: NOT LOADED (clocks below are the real ones)\n\n");
    }

    for (;;) {
        sample();
        if (interval <= 0.0)
            break;
        putchar('\n');
        usleep((useconds_t)(interval * 1e6));
    }
    return 0;
}
