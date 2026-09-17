# nimcsp Portability: Status and Plan

**Current status: x86-64 Linux only. No Windows or macOS port exists in
this folder or anywhere else in this project.**

This document exists instead of a fabricated Windows/macOS port for a
specific reason: the developer environment has no Windows or macOS
compiler, runtime, or hardware available to build or run code against.
Every line of asm and every correctness claim in the main library was
earned through actual execution — real crashes, real gdb sessions, real
repeated stress runs, real ThreadSanitizer output (see the main README's
"Correctness notes"). Writing hand-tuned x86-64 asm and OS-integration
code for two platforms I cannot compile, run, or debug on, and shipping
it under this library's name, would be the exact opposite of that
practice — untested code claiming to be a port is worse than no port at
all, because it invites trust the work hasn't earned.

What follows instead is a precise, technically grounded account of
**exactly what is platform-specific today**, and what a real port would
actually require, written by someone who has spent an entire
development cycle inside this codebase's platform-dependent internals
and knows precisely where the bodies are buried.

---

## What's actually portable already

More of the library than you might expect has no Linux-specific
dependency at all:

- `chan.nim`, `sync.nim` (Mutex/WaitGroup/Once/RWMutex logic),
  `scheduler.nim`'s scheduling *policy* (work-stealing algorithm,
  backlog/cooldown-based worker growth), `rbq.nim`'s lock-free ring
  buffer, `context.nim`, `runtime.nim` — all pure Nim/C11-atomics logic
  with no OS-specific calls. These would very likely port with zero or
  near-zero changes.
- Threading and mutual exclusion (`pthread_mutex_t`, `pthread_cond_t`,
  `pthread_create`) are used in 10 of the library's 30 source files.
  These have direct, mature equivalents on macOS (native pthreads,
  identical API) and on Windows via MinGW-w64 (which ships a real
  pthreads-win32 implementation Nim can link against) — this is real
  work, not a rewrite, on both platforms.

## What's genuinely platform-specific, and why each one is hard

### 1. The context-switch asm (`context_switch.nim`, `core.nim`) — the hard part

Every hand-written asm block in this library assumes the **System V
AMD64 ABI**: arguments in `rdi, rsi, rdx, rcx, r8, r9`; callee-saved
registers `rbx, rbp, r12-r15`; no mandatory shadow space at a call site.

**macOS (x86-64):** uses the *same* System V AMD64 ABI as Linux. The
asm itself would very likely need no changes at all. The risk here is
narrower and different in kind: this library's struct-layout guards
(`static: doAssert offsetof(...)`) were written and verified against
this specific Nim/GCC/Clang toolchain's actual codegen on Linux — see
the main README's "Correctness notes" for exactly how much real,
executed, debugged verification it took to get those offsets right even
on the *one* platform they were checked on. Every one of those
assertions would need to be re-verified against Apple's toolchain
(Xcode's clang, potentially a different Nim-to-C codegen path), not
assumed to hold just because the ABI matches. **macOS (Apple Silicon /
arm64)** is a different, larger problem — a full asm rewrite for
AArch64's calling convention and register set, not a port.

**Windows x64:** genuinely different ABI. Arguments in `rcx, rdx, r8,
r9` (not `rdi, rsi, ...`); a mandatory 32-byte shadow space the caller
must reserve before any call; and critically, Windows' callee-saved
register set is *larger* — it additionally preserves `rsi` and `rdi`,
which this library's Linux/macOS asm treats as freely available
scratch registers in several places. Every single naked asm block in
`context_switch.nim` and `core.nim` — the anchor save/restore, the
proc yield/restore, the preemption trampoline — would need to be
rewritten against this different convention, not recompiled. This is
the single largest, highest-risk piece of any Windows port.

### 2. Netpoll (`netpoll.nim`) — epoll is Linux-only

`epoll_create`/`epoll_ctl`/`epoll_wait` have no Windows equivalent and
no *direct* macOS equivalent. A macOS port needs `kqueue`/`kevent` — a
different API shape (though a similarly-capable readiness-notification
model, so the port is a rewrite of this one file's implementation, not
a redesign of the interface `scheduler.nim` calls into it through). A
Windows port needs either I/O Completion Ports (IOCP, Windows' native
and much higher-performance async I/O model, but a genuinely different
completion-based rather than readiness-based programming model) or a
`WSAPoll`-based readiness-style shim as a simpler but lower-performance
first step.

### 3. Preemption (`scheduler.nim`'s `SIGALRM`-based path) — Linux/macOS only, and already opt-in

The optional preemptive-scheduling path (`LIBCSP_PREEMPT` env var) uses
POSIX real-time signals (`sigaction`, `SIGALRM`, `pthread_kill`) to
interrupt a running goroutine. This has a direct macOS equivalent (macOS
is POSIX-signal-compliant) but no Windows equivalent at all — Windows
would need an entirely different mechanism (a dedicated watchdog thread
calling `SuspendThread`/inspecting/`ResumeThread`, which is a
meaningfully different and riskier primitive than a signal handler).
The saving grace: this path is already off by default, gated behind an
environment variable. A first Windows port could reasonably ship
without preemption at all — cooperative-only scheduling, matching what
most of this library's own test suite already exercises — and add
preemption as a later, separate piece of work.

### 4. The custom memory allocator (`mem.nim`) — likely fine, unverified

The 3-level virtual-memory-backed stack allocator uses `mmap`-family
calls for reserving address space. Both Linux and macOS have `mmap`
with compatible semantics for what this allocator needs. Windows would
need `VirtualAlloc`/`VirtualFree` in its place — a real but bounded
rewrite of this one file's OS-facing layer, with the allocation
*algorithm* itself (the 3-level paging, the per-core heap routing for
cross-thread-safe stack frees) unlikely to need any change at all.

---

## A realistic porting sequence, if this is ever undertaken

1. **macOS x86-64 first.** Same ABI as the already-verified Linux asm,
   so the highest-risk component (context switching) is the lowest
   incremental risk here. Real work: re-verify every struct-layout
   assertion against Apple's toolchain by actually building and running
   on real Apple hardware (not assuming compatibility), and rewrite
   `netpoll.nim` against `kqueue`.
2. **Windows x64, cooperative-only, no preemption.** The real work: a
   full, careful rewrite of every naked asm block against the Windows
   x64 calling convention (different argument registers, mandatory
   shadow space, larger callee-saved set), plus either an IOCP-based or
   `WSAPoll`-based `netpoll.nim`.
3. **Windows preemption, and/or Apple Silicon (arm64),** as clearly
   separated, later follow-ups — each is a genuinely distinct body of
   work (a different interruption mechanism; a full AArch64 asm rewrite,
   respectively), not a small delta on top of the above.

At every step: build it, run it, break it, gdb it, stress-test it
exactly the way the Linux implementation was — on real hardware for that
platform, not by inference from "the code looks like it should work."
That process is what this library's correctness claims are actually
built on, and a port that skipped it wouldn't be able to make the same
claims.
