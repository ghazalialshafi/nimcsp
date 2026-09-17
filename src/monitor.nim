## monitor.nim
## Background monitor thread.

import std/[atomics, posix]
import csp_proc_types
import core
import timer
import scheduler
import netpoll

const MonitorMaxSleepMicrosecs = 10_000

proc cspMonitor(data: pointer): pointer {.noconv, exportc: "csp_monitor".} =
  var duration: int64 = 1
  while true:
    var polledNet = false
    var sN, eN: ptr CspProc
    if cspNetpollPoll(sN, eN, 0) > 0:
      polledNet = true
      var p = sN
      while p != nil:
        let nxt = p.next
        p.next = nil
        cspSchedulerSubmitRunnable(p)
        p = nxt

    var polledTimer = false
    var sT, eT: ptr CspProc
    if cspTimerPoll(sT, eT) > 0:
      polledTimer = true
      var p = sT
      while p != nil:
        let nxt = p.next
        p.next = nil
        cspSchedulerSubmitRunnable(p)
        p = nxt

    if not polledNet and not polledTimer:
      discard usleep(uint32(duration))
      duration = duration * 2
      if duration > MonitorMaxSleepMicrosecs:
        duration = MonitorMaxSleepMicrosecs
    else:
      duration = 1
  nil

proc cspMonitorInit*(): bool {.exportc: "csp_monitor_init".} =
  var tid: Pthread
  var attr: Pthread_attr
  if pthread_attr_init(addr attr) != 0: return false
  if pthread_attr_setdetachstate(addr attr, PTHREAD_CREATE_DETACHED) != 0: return false
  if pthread_create(addr tid, addr attr, cspMonitor, nil) != 0: return false
  discard pthread_attr_destroy(addr attr)
  true
