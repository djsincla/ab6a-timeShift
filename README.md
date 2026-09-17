# timeshift

A per-process clock shim for macOS. Runs a program with its wall clock offset,
scaled, or pinned to a fixed instant, without touching the system clock and
without affecting anything else running on the machine.

Resolution is one nanosecond, so sub-second work — a ±5 s window in 0.1 s
increments, say — is well inside its range, which is ±292 years.

```
make
bin/timeshift --offset -90m -- /path/to/your/program
bin/timeshift --offset 250ms --rate 2 -- ./myapp
bin/timeshift --at '2030-01-01 09:00:00' -- ./myapp
```

## How it works

The shim is a dylib injected with `DYLD_INSERT_LIBRARIES`. It uses dyld's
`__DATA,__interpose` mechanism, which rewrites the bind targets for a chosen
set of symbols in every loaded image *except* the one declaring the
interpositions — so the library can call the real functions by their ordinary
names.

Every clock read is transformed as:

```
out = anchor + (in - anchor) * rate + offset
```

`anchor` is that clock's value at injection, so `--rate` diverges from the
moment the program starts rather than from the epoch.

### What is interposed

| Symbol | Why |
|---|---|
| `gettimeofday` | C code, and CoreFoundation's own clock source |
| `clock_gettime` (`CLOCK_REALTIME`) | modern C/C++, Go, Rust, Swift |
| `clock_gettime_nsec_np` | Apple's preferred fast path |
| `time` | legacy C |
| `mach_absolute_time`, `mach_approximate_time` | monotonic; `--monotonic` only |
| `mach_continuous_time`, `mach_continuous_approximate_time` | monotonic; `--monotonic` only |

`CFAbsoluteTimeGetCurrent`, `NSDate`, Swift's `Date` and `DispatchWallTime`
are covered transitively: CoreFoundation reads the clock through
`gettimeofday`, which is interposed. Interposing CF *as well* double-shifts it
— a real bug this project hit and removed. If a future macOS changes CF's
clock source, `timeshift-probe` will show the CF row disagreeing with the
others, which is exactly what that row is there to catch.

CPU-time clocks (`CLOCK_PROCESS_CPUTIME_ID`, `CLOCK_THREAD_CPUTIME_ID`)
measure consumption rather than time of day and are deliberately left alone.

## Usage

```
timeshift [options] -- <program> [args...]

  --offset SPEC     shift the clock by SPEC: 250ms, -1.5s, 0.1s, 2h, -3d
  --at WHEN         pin "now" to WHEN, in local time: '2030-01-01 09:00:00',
                    or @1893456000.25 for epoch seconds
  --rate R          run the clock at R times real speed (default 1.0)
  --monotonic       also shift mach_absolute_time / CLOCK_MONOTONIC
  --control FILE    take offset and rate live from a control file
  --debug           print the shim's configuration to stderr at startup
```

`DYLD_INSERT_LIBRARIES` is inherited, so child processes are shifted too.

### Live adjustment

With `--control`, the shim mmaps a small shared block and re-reads it on every
clock call, so another process can move a running program's clock:

```sh
bin/timeshift-ctl init /tmp/app.ctl --offset 0
bin/timeshift --control /tmp/app.ctl -- ./myapp &

bin/timeshift-ctl set   /tmp/app.ctl --offset -2.5s   # jump back 2.5 s
bin/timeshift-ctl nudge /tmp/app.ctl --offset 100ms   # step forward 0.1 s
bin/timeshift-ctl set   /tmp/app.ctl --rate 1.0001    # run slightly fast
bin/timeshift-ctl show  /tmp/app.ctl
```

Changes take effect on the target's next clock read. Note that lowering the
offset makes the program's wall clock go **backwards**, which some code
handles badly — that is a property of what you asked for, not a bug.

### Verifying

`timeshift-probe` reads every interposed entry point and prints what each one
says. Run it unshimmed for a baseline, then under the shim: all the wall-clock
rows should agree with each other, and disagree with the baseline by exactly
your offset.

```sh
bin/timeshift-probe                                   # baseline
bin/timeshift --offset -90m -- bin/timeshift-probe    # shifted
make test                                             # both, plus a rate change
```

The `time()` row always trails the others by a sub-second amount. That is
correct: it returns whole seconds.

## Will my target accept injection?

Run `bin/timeshift-check <binary-or-.app>` first. dyld strips every `DYLD_*`
variable from a restricted process **silently** — the program just runs with
the real clock and nothing tells you why.

A target is restricted if it is setuid/setgid, carries entitlements, uses the
hardened runtime with library validation, has a `__RESTRICT` segment, or is an
Apple platform binary. With SIP on, that last category covers everything in
`/System`, `/bin`, `/sbin`, `/usr/bin` and `/usr/sbin` — so `/bin/date` can
never be shimmed, and neither can any Apple app.

This works well for:

- programs you build yourself (the common case — no signing changes needed)
- third-party binaries without the hardened runtime
- anything you are willing to re-sign a **copy** of, accepting that re-signing
  invalidates notarization and usually breaks Keychain, iCloud and App Groups:

  ```sh
  cp -R /Applications/Some.app /tmp/Some.app
  codesign -f -s - --deep --option runtime \
      --entitlements ents.plist /tmp/Some.app
  # ents.plist grants com.apple.security.cs.disable-library-validation
  ```

## Recipe: WSJT-X

WSJT-X ships Developer ID–signed with the hardened runtime and no
`disable-library-validation`, so it rejects the shim as delivered. Make an
injectable copy once, then launch that copy:

```sh
bin/timeshift-resign /Applications/wsjtx.app "/Applications/wsjtx shift.app"
bin/timeshift --offset -0.4s -- "/Applications/wsjtx shift.app/Contents/MacOS/wsjtx"
```

Launch the executable inside the bundle, **not** `open -a`. `open` hands the
request to launchd, which starts the app in a fresh environment, and
`DYLD_INSERT_LIBRARIES` never reaches it.

To adjust while it runs — useful for walking DT without restarting a session:

```sh
bin/timeshift-ctl init /tmp/wsjtx.ctl --offset 0
bin/timeshift --control /tmp/wsjtx.ctl -- "/Applications/wsjtx shift.app/Contents/MacOS/wsjtx" &
bin/timeshift-ctl nudge /tmp/wsjtx.ctl --offset 100ms
```

Notes specific to WSJT-X:

- **`jt9` is covered.** WSJT-X spawns it per decode cycle, and both the
  inherited `DYLD_INSERT_LIBRARIES` and the re-signed helper binaries mean the
  decoder sees the same clock as the GUI.
- **Leave `--monotonic` off.** WSJT-X aligns its 15-second slots off the wall
  clock; shifting the monotonic clock as well only perturbs Qt's timers.
- **Your log moves with the clock.** ADIF QSO times, PSK Reporter spots and
  `ALL.TXT` all record the shifted time. If you are correcting a clock that is
  genuinely wrong that is the point; if you are experimenting, log to a copy.
- **First launch re-prompts for the microphone.** The copy has a new
  signature, so its TCC grant starts empty. The `audio-input` entitlement is
  carried over by `timeshift-resign`.
- **Settings are shared with the original.** Same bundle identifier means the
  same config. Use `--rig-name` if you want the copy kept separate, and do not
  run both at once on one rig.


## Limits

- **Nothing outside the process moves.** File timestamps, `kqueue` and
  `dispatch` timer *firing*, log timestamps, and TLS certificate validity
  checks performed inside other processes all stay on real time.
- **`--monotonic` is a blunt instrument.** Shifting `mach_absolute_time`
  shifts GCD deadlines, animation and network timeouts with it. Leave it off
  unless the target genuinely reads the monotonic clock for its own logic.
- **Time is read, not slewed.** Changing the offset jumps the clock. For a
  machine-wide gradual correction instead, the system call you want is
  `adjtime(2)`.
- **A narrow unshifted window at startup.** Clock reads made before the
  library's constructor runs — from inside libSystem's own initializers —
  pass through untransformed. This is deliberate. The first interposed call
  can arrive from libcorecrypto's initializer, where TLS is not yet
  bootstrapped, `os_once` is not re-entrant, and the malloc zone is not ready;
  all three of those crash a shim that tries to do real work there. It is also
  why debug output is hand-formatted to `write(2)` rather than printed.

## Alternatives

If the target is an Apple binary or refuses injection, a VM with host time
sync disabled is the reliable answer. To move the whole machine instead,
disable time sync (`sudo systemsetup -setusingnetworktime off`, otherwise
`timed` re-syncs under you) and use `settimeofday(2)` to jump or `adjtime(2)`
to slew.

## Layout

```
src/timeshift.c   the injected dylib
src/tsctl.c       timeshift-ctl, writes the shared control block
src/probe.c       timeshift-probe, reads every interposed clock
bin/timeshift     wrapper that sets up the environment and execs
bin/timeshift-check  reports whether a target will accept injection
bin/timeshift-resign make an injectable ad-hoc-signed copy of a hardened .app
```

Built universal (arm64 + x86_64) so it can also be injected into processes
running under Rosetta, and ad-hoc signed, which arm64 requires.
