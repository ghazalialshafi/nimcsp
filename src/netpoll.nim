## netpoll.nim
## epoll-based async network I/O integration.

import std/[posix, atomics]
import csp_proc_types
import core
import timer
import context_switch

{.passC: "-D_GNU_SOURCE".}

# ─── epoll wrappers ───────────────────────────────────────────────────────────

const
  EPOLLERR*   = 0x00000008u32
  EPOLLHUP*   = 0x00000010u32
  EPOLLIN*    = 0x00000001u32
  EPOLLOUT*   = 0x00000004u32
  EPOLL_CTL_ADD* = 1
  EPOLL_CTL_DEL* = 2

type
  EpollEvent* {.importc: "struct epoll_event", header: "<sys/epoll.h>".} = object
    events*: uint32
    # data is a union in C, we'll access it via emit

proc epoll_create1(flags: cint): cint {.importc, header: "<sys/epoll.h>".}
proc epoll_ctl(epfd, op, fd: cint, event: ptr EpollEvent): cint {.importc, header: "<sys/epoll.h>".}
proc epoll_wait(epfd: cint, events: ptr EpollEvent, maxEvents, timeout: cint): cint {.importc, header: "<sys/epoll.h>".}
proc getrlimit(resource: cint, rlim: ptr RLimit): cint {.importc, header: "<sys/resource.h>".}
proc eventfd(initval: cuint, flags: cint): cint {.importc: "eventfd", header: "<sys/eventfd.h>".}

const RLIMIT_NOFILE = 7

# ─── Waiter per fd ───────────────────────────────────────────────────────────

type
  CspNetpollWaiter = object
    registered:  bool
    waitingEvt:  uint32
    `proc`:      Atomic[ptr CspProc]
    timer:       ptr CspTimer

# ─── Global netpoll state ────────────────────────────────────────────────────

type
  CspNetpollState = object
    epfd:       cint
    wakeupFd:   cint
    waitersCap: int
    waiters:    ptr UncheckedArray[CspNetpollWaiter]
    evts:       array[128, EpollEvent]
    lock:       Pthread_mutex
    registeredCount: Atomic[int]

var np: CspNetpollState

proc cspNetpollInit*(): bool {.exportc: "csp_netpoll_init".} =
  var r: RLimit
  if getrlimit(RLIMIT_NOFILE, addr r) == -1 or r.rlim_max == 0:
    return false
  np.waitersCap = int(r.rlim_max)
  np.waiters = cast[ptr UncheckedArray[CspNetpollWaiter]](
    alloc0(np.waitersCap.uint * uint(sizeof(CspNetpollWaiter))))
  if np.waiters == nil: return false
  np.epfd = epoll_create1(0)
  if np.epfd == -1: return false

  np.wakeupFd = eventfd(0, 0)
  if np.wakeupFd != -1:
    var evt: EpollEvent
    evt.events = EPOLLIN
    {.emit: "`evt`.data.fd = `np`.wakeupFd;".}
    discard epoll_ctl(np.epfd, EPOLL_CTL_ADD, np.wakeupFd, addr evt)

  discard pthread_mutex_init(addr np.lock, nil)
  true

proc cspNetpollWakeup*() {.exportc: "csp_netpoll_wakeup".} =
  if np.wakeupFd != -1:
    var val: uint64 = 1
    discard posix.write(np.wakeupFd, addr val, 8)

proc cspNetpollRegister*(fd: cint): bool {.exportc: "csp_netpoll_register".} =
  if fd < 0 or fd >= np.waitersCap: return false
  var flags = fcntl(fd, F_GETFL, 0)
  if flags != -1:
    flags = fcntl(fd, F_SETFL, flags or O_NONBLOCK)
  if flags == -1: return false
  var evt: EpollEvent
  evt.events = EPOLLIN or EPOLLOUT
  {.emit: "`evt`.data.fd = `fd`;".}
  if epoll_ctl(np.epfd, EPOLL_CTL_ADD, fd, addr evt) == -1:
    discard epoll_ctl(np.epfd, 3, fd, addr evt)
  np.waiters[fd].registered = true
  discard np.registeredCount.fetchAdd(1, moRelaxed)
  true

proc cspNetpollUnregister*(fd: cint): bool {.exportc: "csp_netpoll_unregister".} =
  if fd < 0 or fd >= np.waitersCap: return false
  if epoll_ctl(np.epfd, EPOLL_CTL_DEL, fd, nil) == -1:
    return false
  np.waiters[fd].registered = false
  discard np.registeredCount.fetchSub(1, moRelaxed)
  return true

## Number of fds currently registered with the poller -- used by the
## scheduler's deadlock detector to distinguish "no I/O ready right now"
## from "no I/O could EVER become ready" (a registered fd means the latter
## is false: something could arrive on it at any time).
proc cspNetpollPendingCount*(): int {.exportc: "csp_netpoll_pending_count".} =
  np.registeredCount.load(moRelaxed)

# ─── Wait (yields the current proc) ─────────────────────────────────────────

proc cspNetpollWait(fd: cint, timeout: CspTimerDuration, evt: uint32): int =
  let core = cspThisCore
  if core == nil or core.running == nil: return -1
  let running = core.running

  let waiter = addr np.waiters[fd]
  waiter.waitingEvt = evt
  running.statSet(CspProcStatNetpollWaiting)
  waiter.`proc`.store(running, moSequentiallyConsistent)
  waiter.timer = nil

  core.running = nil
  cspCoreYield(running, addr core.anchor)

  var expected = running
  discard waiter.`proc`.compareExchange(expected, nil)
  int(running.statGet())

proc cspNetpollWaitRead*(fd: cint, timeout: CspTimerDuration): int {.
    exportc: "csp_netpoll_wait_read".} =
  cspNetpollWait(fd, timeout, EPOLLIN)

proc cspNetpollWaitWrite*(fd: cint, timeout: CspTimerDuration): int {.
    exportc: "csp_netpoll_wait_write".} =
  cspNetpollWait(fd, timeout, EPOLLOUT)

proc cspNetpollPoll*(start, `end`: var ptr CspProc, blockMs: cint): int {.
    stackTrace: off, exportc: "csp_netpoll_poll".} =
  if pthread_mutex_trylock(addr np.lock) != 0: return 0

  let n = epoll_wait(np.epfd, addr np.evts[0],
    cint(np.evts.len), blockMs)

  if n <= 0:
    discard pthread_mutex_unlock(addr np.lock)
    return 0

  var count = 0
  var head: ptr CspProc = nil
  var tail: ptr CspProc = nil

  for i in 0 ..< n:
    var fd: cint
    {.emit: "`fd` = `np`.evts[`i`].data.fd;".}

    if fd == np.wakeupFd:
      var val: uint64
      discard posix.read(np.wakeupFd, addr val, 8)
      continue

    if fd < 0 or fd >= np.waitersCap: continue
    let waiter = addr np.waiters[fd]
    var p = waiter.`proc`.load(moAcquire)
    if p == nil: continue

    var mask: uint32 = 0
    let evts = np.evts[i].events
    if (evts and EPOLLIN)  != 0: mask = mask or EPOLLIN
    if (evts and EPOLLOUT) != 0: mask = mask or EPOLLOUT
    if (evts and (EPOLLERR or EPOLLHUP)) != 0:
      mask = mask or EPOLLIN or EPOLLOUT

    if (mask and waiter.waitingEvt) != 0:
      if p.yielded.load(moAcquire) == 0: continue

      # Use a temporary to avoid compareExchange issues if p changed
      var expectedP = p
      if not waiter.`proc`.compareExchange(expectedP, nil): continue

      var oval = CspProcStatNetpollWaiting
      if p.statCas(oval, CspProcStatRunnable):
        p.next = nil
        if tail != nil:
          tail.next = p
          tail = p
        else: head = p; tail = p
        inc count

  discard pthread_mutex_unlock(addr np.lock)
  if count > 0:
    start = head
    `end`  = tail
  count

proc cspNetpollDestroy*() =
  for i in 0 ..< np.waitersCap:
    if np.waiters[i].registered:
      discard cspNetpollUnregister(cint(i))
  dealloc(np.waiters)
  discard close(np.epfd)
  if np.wakeupFd != -1: discard close(np.wakeupFd)
  discard pthread_mutex_destroy(addr np.lock)

# ─── Coroutine-safe read/write ────────────────────────────────────────────────

proc cspRead*(fd: cint, buf: pointer, n: csize_t): int {.exportc: "csp_read".} =
  while true:
    let r = posix.read(fd, buf, n.int)
    if r >= 0: return int(r)
    if errno == EAGAIN or errno == EWOULDBLOCK:
      discard cspNetpollWaitRead(fd, 0)
      continue
    if errno == EINTR: continue
    return int(r)

proc cspWrite*(fd: cint, buf: pointer, n: csize_t): int {.exportc: "csp_write".} =
  while true:
    let r = posix.write(fd, buf, n.int)
    if r >= 0: return int(r)
    if errno == EAGAIN or errno == EWOULDBLOCK:
      discard cspNetpollWaitWrite(fd, 0)
      continue
    if errno == EINTR: continue
    return int(r)
