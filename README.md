# nimcsp — Go-style CSP Goroutines in Pure Nim

Implements Go-style coroutines (goroutines), channels, select, WaitGroups,
Mutexes, contexts, timers, tickers, epoll-based async I/O, a virtual memory
manager, and an M:N work-stealing scheduler with optional preemption — all in Nim.

---

## Architecture

```
nimcsp/
├── nimcsp.nimble          # package file
├── src/
│   ├── csp.nim            # ← public API (import this)
│   ├── platform.nim       # platform types & flags
│   ├── common.nim         # cspLikely/cspUnlikely/cspExp etc.
│   ├── mutex.nim          # spinlock (atomic_flag equivalent)
│   ├── rbq.nim            # lock-free ring-buffer queues (ss/sm/ms/mm/raw)
│   ├── rbtree.nim         # red-black tree
│   ├── proc_types.nim     # CspProc struct + stat helpers
│   ├── proc_extra.nim     # per-proc extra state (channels, preemption)
│   ├── runq.nim           # local (LRunq) and global (GRunq) run queues
│   ├── timer.nim          # min-heap timer subsystem
│   ├── timer_ext.nim      # time.After / Ticker
│   ├── cond.nim           # proc-level conditional variable
│   ├── context_switch.nim # x86-64 inline-asm context save/restore
│   ├── core.nim           # per-OS-thread execution core
│   ├── proc.nim           # proc allocation / destruction
│   ├── corepool.nim       # per-CPU pool of cores
│   ├── rand.nim           # xoshiro256** PRNG
│   ├── chan.nim            # Go-style channels (buffered, unbuffered, select)
│   ├── netpoll.nim        # epoll async I/O
│   ├── worker.nim         # OS worker thread
│   ├── scheduler.nim      # M:N work-stealing scheduler + SIGALRM preemption
│   ├── sched.nim          # public scheduler API (async/sync/yield/block/hangup)
│   ├── monitor.nim        # background monitor (timer + netpoll polling)
│   ├── sync.nim           # coroutine-aware Mutex + WaitGroup
│   ├── context.nim        # Go-style cancellable contexts (cancel/deadline/timeout/value)
│   ├── csp_tsan.nim       # optional ThreadSanitizer fiber-switch annotations
│   ├── mem.nim            # virtual memory manager (3-level paging, per-CPU heaps)
│   ├── runtime.nim        # runtime introspection
│   ├── example.nim        # usage example
│   └── cspcli.nim         # CLI entry point
├── tests/
│   ├── run_all.sh          # test runner used by `nimble test`/`testAll` and CI
│   └── *.nim               # see "Testing" below
└── plugin/
    ├── fs.nim             # filesystem helpers for cspcli
    ├── namer.nim          # process name generation / parsing
    └── sa.nim             # stack analyzer → generates config.c
```

---

## Building

```bash
# Build the shared library
nim c --app:lib --threads:on --mm:arc --stacktrace:off -d:useMalloc \
      --passC:"-D_GNU_SOURCE" --passL:"-pthread" \
      -o:libcsp.so src/csp.nim

# Build the CLI
nim c --threads:on --mm:arc ---stacktrace:off -d:useMalloc --path:. -o:cspcli src/cspcli.nim
```

`cspcli` needs `--path:.` from the project root: it imports `plugin/{fs,namer,sa}`,
which live outside `src/`, and Nim doesn't search the project root by
default (this was previously broken — `nim c src/cspcli.nim` failed
outright with "cannot open file: plugin/fs"; the `nimble build_cli` task
now bakes in the correct flag).

Or via nimble, which bakes in the correct flags:

```bash
nimble build_lib
nimble build_cli
```

---

## Testing

For a full, real-world-shaped demonstration of the library under load —
not a toy loop — see [`showcase/`](showcase/README.md): a Resilient
High-Throughput Distributed Microservices Telemetry Engine exercising
dynamic worker pools, context-timeout-bounded lifetimes, multiplexed
shutdown via `select`, RWMutex-protected shared state, and deterministic
`WaitGroup` teardown, with a full code walkthrough and a Colab notebook
you can run immediately.

```bash
nimble test        # quick pass (few repetitions), for local iteration
nimble testAll      # full suite, matching what CI runs
# or directly:
bash tests/run_all.sh [--quick]
```

Every correctness/feature test is run multiple times, not once: goroutine
scheduling races are inherently timing-dependent, and a single passing run
proves very little (several of the bugs described below only reproduced
intermittently, some as rarely as 1 in 30 runs). `tests/run_all.sh` is the
same process used to develop and verify this library — see it for the
exact repetition counts and expected exit codes per test.

Test suite (`tests/`):
- `test_block`, `test_pipe`, `test_select`, `test_net` — core mechanics:
  real OS blocking calls, pipes, select, networking.
- `test_once_rwmutex` — `sync.Once` and `sync.RWMutex`, including a check
  that genuinely proves concurrent readers overlap (not just "didn't
  crash").
- `test_context`, `test_context_value` — cancellation, deadlines,
  timeouts, and value propagation, including races between an explicit
  cancel and a pending timeout.
- `test_deadlock`, `test_not_deadlock_timer` — the deadlock detector both
  fires on a real deadlock and does *not* fire on a goroutine legitimately
  waiting on a timer.
- `stress_fanout`, `stress_mutex`, `stress_churn` — adversarial,
  high-goroutine-count workloads that check actual data integrity (a
  per-message ledger, an exact contended-counter value, etc.), not just
  "the process didn't crash."

### Running under ThreadSanitizer

```bash
nim c --threads:on --mm:arc --stacktrace:off -d:useMalloc -d:release -d:cspTsanFibers --cc:clang \
      --passC:"-fsanitize=thread" --passL:"-fsanitize=thread" \
      -o:test_block.tsan tests/test_block.nim
TSAN_OPTIONS="halt_on_error=0" ./test_block.tsan
```

`-d:cspTsanFibers` (see `src/csp_tsan.nim`) announces this runtime's manual
stack switches to TSan via its public fiber API, without which TSan's own
internal bookkeeping gets corrupted by the `jmp`-based switches (observed
during development as TSan crashing inside its own code, not in anything
this library owns). It's a no-op — the `__tsan_*` symbols are never even
referenced — unless you pass this flag, so it has zero effect on normal
builds. See "Known limitations" below for what it does and doesn't cover.

---

## Performance

Measured in the development sandbox (single CPU core — deliberately
adversarial for an M:N scheduler; expect better throughput and better
scaling with goroutine count on real multi-core hardware). See
`tests/bench_million.nim`.

| Goroutines created & executed | Time      | Rate         |
|--------------------------------|-----------|--------------|
| 10,000                         | ~0.1-0.4s | ~30-80k/s    |
| 100,000                        | ~0.5-0.8s | ~120-190k/s  |
| 1,000,000                      | ~2.5-3.7s | ~270-410k/s  |

**Important caveat on the table above:** `bench_million.nim`'s task does
one atomic increment and returns immediately — it never blocks or
yields, so it never touches `cspCoreYield`/`cspProcRestore`, the actual
hand-written asm context-switch path. It's a real, honest measurement of
allocator + run-queue throughput, not of "concurrent multitasking"

For the actual context-switch path, see `tests/bench_context_switch.nim`:
two goroutines ping-ponging over an **unbuffered** channel, which cannot
complete without a real handoff through the asm switching code, on every
single operation. Measured in the same sandbox:

| Metric                          | Value              |
|----------------------------------|---------------------|
| Round trips (500,000 total)      | ~0.97-1.04s          |
| Round trips/s                    | ~480,000-515,000     |
| Context switches per second      | ~960,000-1,030,000   |
| Cost per context switch           | **~970ns-1.04µs** (upper-bound estimate — see file for why) |

That benchmark also caught a real bug: a newly created goroutine's
floating-point exception-mask state (`mxcsr`/`x87cw`) was never given a
sane initial value, so a fresh goroutine's first ordinary floating-point
operation could raise `SIGFPE` on otherwise-unused memory. See
"Correctness notes" below — this went unnoticed through extensive prior
stress testing specifically because none of that testing did any
floating-point arithmetic inside a goroutine.


If your workload creates goroutines in large synchronous bursts, set
`cspMaxProcsHint` to roughly your expected peak *before* calling
`cspInit()`.

---

## Usage

```nim
import nimcsp/csp

# Launch a goroutine
proc myTask(arg: pointer) {.cdecl.} =
  echo "hello from goroutine"

discard cspProcCreate(0, myTask, nil)
cspYield()

# Channels
let ch = chanNew(0u)   # unbuffered
discard chanSend(ch, myValuePtr)
let v = chanRecv(ch, nil)

# WaitGroup
var wg: WaitGroupT
wgInit(wg)
wgAdd(wg, 1)
# ... in goroutine: wgDone(wg)
wgWait(wg)

# Select
var cases: array[2, CspSelectCase]
cases[0] = CspSelectCase(ch: ch1, op: CspSelectOp.Recv, val: addr myVal)
cases[1] = CspSelectCase(ch: ch2, op: CspSelectOp.Send, val: cast[ptr pointer](addr sendVal))
let chosen = cspSelect(addr cases[0], 2)

# Context: cancellation, deadlines, timeouts, values
let ctx = cspContextWithCancel(cspContextBackground())
cspContextCancel(ctx)

let timed = cspContextWithTimeout(cspContextBackground(), 5_000_000_000) # 5s
# ... on the other end:
var ok: bool
discard recvGoChan(cspContextDone(timed), addr ok)
case cspContextErr(timed)
of CspContextErr.DeadlineExceeded: echo "timed out"
of CspContextErr.Canceled:         echo "canceled"
of CspContextErr.None:             discard # unreachable once Done fires

let withVal = cspContextWithValue(cspContextBackground(), "requestID", cast[pointer](42))
let v2 = cspContextValue(withVal, "requestID")

# Timer / Ticker
let done = timeAfter(CspTimerSecond)
let ticker = tickerNew(CspTimerMillisecond * 100)
tickerStop(ticker)

# Mutex
var m: MutexT
mutexInit(m)
mutexLock(m)
mutexUnlock(m)

# Once: fn runs exactly once, every caller blocks until it has
var once: OnceT
onceInit(once)
onceDo(once) do (): echo "runs exactly once, no matter how many call this"

# RWMutex: many concurrent readers, or one exclusive writer, writer-preference
var rw: RWMutexT
rwMutexInit(rw)
rwMutexRLock(rw); discard "read"; rwMutexRUnlock(rw)
rwMutexLock(rw);  discard "write"; rwMutexUnlock(rw)
```

If every goroutine is asleep and nothing (no timer, no pending I/O) could
ever wake any of them, the runtime detects it and exits with a message
matching Go's runtime, instead of hanging forever:

```
fatal error: all goroutines are asleep - deadlock!
  2 goroutine(s) still alive, none runnable, no timers armed, no I/O pending.
```
(exit code 2)

---

## cspcli Workflow

```bash
# 1. Initialize working directory
cspcli init --working-dir=/tmp/libcsp

# 2. Compile your code with the plugin (collects .sf and .cg files)
gcc -fplugin=./libcsp.so -fplugin-arg-libcsp-so-working-dir=/tmp/libcsp \
    -c myapp.c -o myapp.o

# 3. Analyze stack usage → generates config.c
cspcli analyze \
    --working-dir=/tmp/libcsp \
    --installed-prefix=/usr/local \
    --max-threads=512 \
    --max-procs-hint=50000

# 4. Compile config.c and link
gcc config.c myapp.o -lcsp -o myapp

# 5. Clean up
cspcli clean --working-dir=/tmp/libcsp
```

---

## Key Design Decisions

| C Original | Nim Port |
|------------|----------|
| `__attribute__((naked))` + inline ASM | `{.noStackFrame.}` + `{.emit.}` with GCC ASM |
| `_Thread_local csp_core_t *csp_this_core` | `var cspThisCore {.threadvar.}: ptr CspCore` |
| Union for proc registers | `CspProcRegisters {.union.}` |
| `atomic_*` C11 | `std/atomics` |
| `pthread_*` | `std/posix` `Pthread*` |
| `csp_chan_declare` / `csp_chan_define` macros | Generic `RbqBase[T, FP, SP]` |
| `csp_likely` / `csp_unlikely` | Template wrappers |
| Naked function wrappers for goroutine entry | `{.emit.}` inline ASM blocks |
| 3-level virtual memory manager | `mem.nim` with same layout |
| Red-black tree | `rbtree.nim` |
| `csp_sched_async` / `csp_sched_sync` macros | `cspAsync` / `cspSync` templates |

---

## Environment Variables

| Variable | Effect |
|----------|--------|
| `LIBCSP_PRODUCTION` | Enable the M:N work-stealing scheduler |
| `LIBCSP_PREEMPT` | Enable SIGALRM-based goroutine preemption |

---

## Platform

x86-64 Linux only (uses epoll, POSIX threads, inline x86-64 assembly).

---

## Known limitations

- **`context.Value()` uses `cstring` keys**, not Go's arbitrary
  comparable-interface keys. Simpler and adequate for most use, but Go's
  docs recommend unexported types specifically to avoid string-key
  collisions between unrelated packages — that guardrail doesn't exist
  here, so pick keys carefully.
- **ThreadSanitizer coverage is partial.** `-d:cspTsanFibers` (see
  `src/csp_tsan.nim`) correctly announces goroutine-to-goroutine and
  goroutine-to-scheduler stack switches, and measurably improved TSan
  results for long-lived goroutines during development (a test that
  reliably crashed TSan's own internals went to zero crashes across
  repeated runs). It does **not** cover high-goroutine-churn workloads:
  each new goroutine's stack is carved out of a custom allocator
  (`mem.nim`) that reuses memory from exited goroutines without ever
  going through `malloc`/`free`, so TSan's allocator-tracking has no idea
  that memory was freed and reused — it can still misattribute an old
  tenant's access history to the new one. Fixing this properly means
  wiring `mem.nim`'s allocator through TSan's malloc-hook API
  (`__tsan_malloc`-equivalent), which was deliberately not attempted:
  getting it subtly wrong risks silent false *negatives* (races TSan
  should catch but doesn't), which is a worse outcome than the current,
  well-understood false positives. Bugs in this codebase have instead
  been found primarily via targeted gdb debugging plus adversarial stress
  tests that check actual data integrity (see `tests/stress_*.nim`) —
  that combination has a solid track record here and doesn't depend on
  this gap being closed.
- **Multi-core parallelism has not been exercised on real multi-core
  hardware** during this project's development (the development sandbox
  had a single CPU core). The scheduler and synchronization primitives
  were verified for correct *concurrent* behavior (interleaving,
  contention, correct exclusion) under heavy stress, which exercises the
  same synchronization logic that matters for true parallelism — but
  running on genuine multi-core hardware before relying on this in
  production is still recommended.
- No API stability guarantees yet (pre-1.0).

---

## Correctness notes

This library's asm-level context switching and lock-free scheduling
mechanics went through substantial debugging to reach their current,
stress-tested state. A few of the more instructive bugs, for anyone
touching this code:

- **Struct-layout drift between the naked asm and Nim's actual generated
  layout is the most dangerous class of bug here**, because it's silent
  in debug builds (zeroed memory hides it) and manifests as flaky,
  optimization-level-dependent segfaults in release builds — e.g. a
  `{.pure.}` enum packs to 1 byte, but asm compared it with a 4-byte
  `cmpl`, reading uninitialized padding as part of the value. Every
  offset the asm depends on now has a `static: doAssert offsetof(...)`
  guard (see `csp_proc_types.nim`, `context_switch.nim`, `core.nim`) —
  keep this pattern for any new asm-touched field.
- **Two different "resume the anchor" code paths must agree on exactly
  what the saved stack pointer means.** One path resumes via `jmp`
  (expects the saved rsp to already account for the return address that
  would otherwise be popped); another used to resume via a manual
  write-to-stack + `retq` trick with the opposite convention. They shared
  the same saved state, so fixing one broke the other. Both now use the
  same `jmp`-based convention — don't reintroduce a second convention
  without re-deriving both sides together.
- **Anything allocated on one goroutine and freed on another must use the
  shared heap** (`allocShared0`/`deallocShared`), never plain
  `alloc0`/`dealloc` — this is an M:N scheduler, goroutines are not
  pinned to an OS thread, and Nim's default allocator is thread-local.
- **A proc marked `Runnable` is not the same as a proc that's actually in
  a run queue.** `cspSchedulerSubmit`'s "already Runnable = someone else
  is handling it" check is only valid for its intended callers (waking a
  `Blocked` waiter); feeding it a proc that a timer/netpoll poll already
  pre-marked `Runnable` silently drops it forever. Use
  `cspSchedulerSubmitRunnable` for that case instead.
- **Every voluntary yield needs to explicitly re-enqueue itself.** Unlike
  blocking on a mutex/channel/timer, a plain yield has no other data
  structure holding a reference to the proc — it must mark itself
  `Runnable` and enqueue before yielding, or it's lost.
- **Uninitialized FP control state is invisible until a goroutine does
  float math.** A new goroutine's `mxcsr`/`x87cw` fields (the saved
  floating-point exception-mask and rounding state, restored via
  `ldmxcsr`/`fldcw` on every context switch) were never given a sane
  initial value — left as whatever the allocator's raw memory happened
  to contain. A zeroed MXCSR unmasks *every* FP exception, including
  Precision, which fires on almost any inexact division — so a fresh
  goroutine's first ordinary floating-point operation could `SIGFPE` on
  memory that hadn't previously been used by a proc that had actually
  run (reused memory from a previously-run proc masked this by luck,
  since it would carry a real, sane saved value). This went unnoticed
  through extensive stress testing because none of that testing did any
  floating-point arithmetic inside a goroutine — a caution about
  coverage, not just correctness: a stress suite exercising the
  concurrency primitives thoroughly can still have a completely blind
  spot for something as basic as "does normal arithmetic work." Found
  via `tests/bench_context_switch.nim`, added specifically to exercise
  the real context-switch path (see that file's header for why
  `bench_million.nim` alone doesn't). Fixed in `cspProcNew` by
  explicitly setting the real x86-64 ABI reset defaults (`0x1F80` /
  `0x037F`) instead of leaving the fields implicitly zero.
- **Code nobody actually runs accumulates real bugs, not just style
  issues.** `src/example.nim` never called `cspInit()` (crashed
  immediately), never waited for its spawned goroutines to finish before
  the process exited (so most of its output silently never appeared), and
  used the thread-local `alloc`/`dealloc` for values passed across a
  channel (exactly the cross-thread heap bug described above). `cspcli`
  didn't compile at all without an undocumented `--path:.` flag, and
  separately had a bare `Option`/`initTable`/`HashSet` reference with no
  matching import. None of this was caught by review; all of it was
  caught by actually building and running these files. Don't assume a
  file compiles or behaves correctly just because it looks reasonable —
  build and run it.
