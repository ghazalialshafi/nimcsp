## context_switch.nim
## x86-64 context switching primitives.

import csp_proc_types
import csp_tsan

# ─── Anchor (scheduler context) ───────────────────────────────────────────────

type
  CspAnchor* = object
    rbp*: int64
    rsp*: int64
    rip*: int64
    rbx*: int64
    r12*: int64
    r13*: int64
    r14*: int64
    r15*: int64

# See the layout-guard comment in csp_proc_types.nim — same rationale applies
# to CspAnchor, which is walked field-by-field via hardcoded offsets below.
static:
  doAssert sizeof(CspAnchor) == 64
  doAssert offsetof(CspAnchor, rbp) == 0x00
  doAssert offsetof(CspAnchor, rsp) == 0x08
  doAssert offsetof(CspAnchor, rip) == 0x10
  doAssert offsetof(CspAnchor, rbx) == 0x18
  doAssert offsetof(CspAnchor, r12) == 0x20
  doAssert offsetof(CspAnchor, r13) == 0x28
  doAssert offsetof(CspAnchor, r14) == 0x30
  doAssert offsetof(CspAnchor, r15) == 0x38

proc cspCoreAnchorSave*(anchor: ptr CspAnchor) {.
    stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_core_anchor_save".} =
  {.emit: """
    __asm__ __volatile__(
      /* NOTE: rsp is saved as (rsp + 8), not rsp itself. This function is
         reached via `call`, so [rsp] holds our caller's pending return
         address, which we deliberately peek at (below) rather than pop, so
         that a later `jmp *rip` can re-enter at this exact point. Because
         `jmp` — unlike the `retq` this call would otherwise perform — never
         consumes that return-address slot, the anchor's saved stack pointer
         must compensate by +8, or every yield/resume cycle through this
         anchor permanently drifts the restored rsp by 8 bytes, silently
         breaking the ABI's 16-byte stack alignment guarantee for the
         lifetime of the OS thread (manifesting much later as SIGSEGV in
         unrelated SSE-using code, e.g. movaps in std/times.getTime). */
      "mov %%rbp,   0x00(%%rdi)\n"
      "lea 0x8(%%rsp), %%rax\n"
      "mov %%rax,   0x08(%%rdi)\n"
      "mov (%%rsp), %%rax\n"
      "mov %%rax,   0x10(%%rdi)\n"
      "mov %%rbx,   0x18(%%rdi)\n"
      "mov %%r12,   0x20(%%rdi)\n"
      "mov %%r13,   0x28(%%rdi)\n"
      "mov %%r14,   0x30(%%rdi)\n"
      "mov %%r15,   0x38(%%rdi)\n"
      "retq\n"
      ::: "memory"
    );
  """.}

proc cspCoreAnchorRestore*(anchor: ptr CspAnchor) {.
    stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_core_anchor_restore".} =
  {.emit: """
    __asm__ __volatile__(
      /* Mirrors cspCoreYield's own inline anchor-restore below: rsp is
         restored directly (no retq-based consumption), and we `jmp` to
         the saved rip rather than pushing it and `retq`-ing to it. Both
         restore paths must agree on what `anchor.rsp` means -- it is the
         exact rsp value execution should have once resumed at anchor.rip,
         matching how cspCoreAnchorSave captures it (see the comment
         there). Do not reintroduce a retq-based variant here without
         re-deriving both sides together. */
      "mov 0x00(%%rdi), %%rbp\n"
      "mov 0x18(%%rdi), %%rbx\n"
      "mov 0x20(%%rdi), %%r12\n"
      "mov 0x28(%%rdi), %%r13\n"
      "mov 0x30(%%rdi), %%r14\n"
      "mov 0x38(%%rdi), %%r15\n"
      "mov 0x10(%%rdi), %%rax\n"
      "mov 0x08(%%rdi), %%rsp\n"
      "jmp *%%rax\n"
      ::: "memory"
    );
  """.}

proc cspCoreYieldRaw(p: ptr CspProc, anchor: ptr CspAnchor) {.
    stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_core_yield".} =
  {.emit: """
    __asm__ __volatile__(
      "stmxcsr   0x20(%%rdi)\n"
      "fstcw     0x24(%%rdi)\n"
      "mov %%rsp, 0x28(%%rdi)\n"
      "mov %%rbp, 0x30(%%rdi)\n"
      "mov %%rbx, 0x38(%%rdi)\n"
      "mov %%r12, 0x40(%%rdi)\n"
      "mov %%r13, 0x48(%%rdi)\n"
      "mov %%r14, 0x50(%%rdi)\n"
      "mov %%r15, 0x58(%%rdi)\n"
      /* Restore anchor registers */
      "mov 0x18(%%rsi), %%rbx\n"
      "mov 0x20(%%rsi), %%r12\n"
      "mov 0x28(%%rsi), %%r13\n"
      "mov 0x30(%%rsi), %%r14\n"
      "mov 0x38(%%rsi), %%r15\n"
      /* Switch to anchor stack */
      "mov 0x08(%%rsi), %%rsp\n"
      "mov 0x00(%%rsi), %%rbp\n"
      /* Set yielded = 1 */
      "movq $1, 0x68(%%rdi)\n"
      /* Load return address and jump */
      "mov 0x10(%%rsi), %%rax\n"
      "jmp *%%rax\n"
      ::: "memory"
    );
  """.}

## Public entry point every blocking primitive calls. Wraps the raw asm
## switch with a TSan fiber-switch announcement (a no-op unless built with
## -d:cspTsanFibers -- see csp_tsan.nim) right before physically leaving
## this goroutine's stack, since after this call returns we're back on the
## OS thread's own native context for a while.
proc cspCoreYield*(p: ptr CspProc, anchor: ptr CspAnchor) {.inline.} =
  cspTsanSwitchToNative()
  cspCoreYieldRaw(p, anchor)

proc cspProcRestore*(p: ptr CspProc) {.
    stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_proc_restore".} =
  {.emit: """
    __asm__ __volatile__(
      /* Wait for yielded == 1 */
      "1:\n"
      "cmpq $1, 0x68(%%rdi)\n"
      "je 2f\n"
      "pause\n"
      "jmp 1b\n"
      "2:\n"
      /* p->yielded = 0 (offset 0x68) */
      "movq $0, 0x68(%%rdi)\n"
      "ldmxcsr 0x20(%%rdi)\n"
      "fldcw   0x24(%%rdi)\n"
      "mov  0x10(%%rdi), %%rax\n"
      "test %%rax, %%rax\n"
      "jz  .Lnormal_restore\n"
      "cmp $1, %%rax\n"
      "je  .Lnew_restore\n"
      "cmp $2, %%rax\n"
      "je  .Lpreempt_restore\n"

      ".Lnormal_restore:\n"
      "mov 0x28(%%rdi), %%rsp\n"
      "mov 0x30(%%rdi), %%rbp\n"
      "mov 0x38(%%rdi), %%rbx\n"
      "mov 0x40(%%rdi), %%r12\n"
      "mov 0x48(%%rdi), %%r13\n"
      "mov 0x50(%%rdi), %%r14\n"
      "mov 0x58(%%rdi), %%r15\n"
      "retq\n"

      ".Lnew_restore:\n"
      "movq $0, 0x10(%%rdi)\n"
      "mov 0x28(%%rdi), %%rsp\n"
      "mov 0x30(%%rdi), %%rbp\n"
      "mov 0x38(%%rdi), %%rbx\n"
      "mov 0x40(%%rdi), %%r12\n"
      "retq\n"

      ".Lpreempt_restore:\n"
      "movq $0, 0x10(%%rdi)\n"
      "mov 0x28(%%rdi), %%rsp\n"
      "pop %%r15\n"
      "pop %%r14\n"
      "pop %%r13\n"
      "pop %%r12\n"
      "pop %%r11\n"
      "pop %%r10\n"
      "pop %%r9\n"
      "pop %%r8\n"
      "pop %%rbp\n"
      "pop %%rdi\n"
      "pop %%rsi\n"
      "pop %%rdx\n"
      "pop %%rcx\n"
      "pop %%rbx\n"
      "pop %%rax\n"
      "retq\n"
      ::: "memory"
    );
  """.}

proc cspProcEntry*() {.stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_proc_entry".} =
  {.emit: """
    __asm__ __volatile__(
      "mov %%r12, %%rdi\n"
      "call *%%rbx\n"
      "call csp_core_proc_exit@plt\n"
      ::: "memory"
    );
  """.}

proc cspAsyncPreempt*() {.stackTrace: off, codegenDecl: "__attribute__((naked)) $# $#$#", exportc: "csp_async_preempt".} =
  {.emit: """
    __asm__ __volatile__(
      "push %%rax\n"
      "push %%rbx\n"
      "push %%rcx\n"
      "push %%rdx\n"
      "push %%rsi\n"
      "push %%rdi\n"
      "push %%rbp\n"
      "push %%r8\n"
      "push %%r9\n"
      "push %%r10\n"
      "push %%r11\n"
      "push %%r12\n"
      "push %%r13\n"
      "push %%r14\n"
      "push %%r15\n"
      "mov %%rsp, %%rdi\n"
      "and $-16, %%rsp\n"
      "jmp csp_preempt_helper@plt\n"
      ::: "memory"
    );
  """.}
