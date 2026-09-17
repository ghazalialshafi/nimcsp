## sa.nim
## Stack usage analyzer: reads .sf and .cg files, generates config.c.
## Equivalent to plugin/sa.hpp

import std/[os, strutils, strformat, tables, sets, deques, algorithm, math]
import fs
import namer

# ─── Types ────────────────────────────────────────────────────────────────────

type
  StackUsageType* {.pure.} = enum
    Static, Dynamic, DynamicBounded, Manually

  StackUsage* = object
    typ*:         StackUsageType
    maxStackSize*: int64
    stackByUser*: int64
    frameSize*:   int64
    procReserved*: int64

  AnalyzerOptions* = object
    isBuildingLibcsp*: bool
    installedPrefix*:  string
    workingDir*:       string
    extraSuFile*:      string
    defaultStackSize*: uint
    cpuCores*:         uint
    maxThreads*:       uint
    maxProcsHint*:     uint

proc defaultOptions*(): AnalyzerOptions =
  AnalyzerOptions(
    isBuildingLibcsp: false,
    installedPrefix:  DefaultInstalledPrefix,
    workingDir:       DefaultWorkingDir,
    extraSuFile:      "",
    defaultStackSize: 1 shl 11,
    cpuCores:         0,
    maxThreads:       1024,
    maxProcsHint:     100_000)

proc defaultStackUsage(): StackUsage =
  StackUsage(typ: StackUsageType.Static, maxStackSize: -1,
             stackByUser: -1, frameSize: -1, procReserved: -1)

# ─── Analyzer ─────────────────────────────────────────────────────────────────

type
  Analyzer* = object
    stackUsages*: Table[string, StackUsage]
    callGraph*:   Table[string, HashSet[string]]
    options*:     AnalyzerOptions
    fs*:          Filesystem

const
  FlagStackByUser = 1
  FlagCspOnly     = 2

proc addCall*(a: var Analyzer, caller, callee: string) =
  a.callGraph.mgetOrPut(caller, initHashSet[string]()).incl(callee)

proc setCallees*(a: var Analyzer, caller: string, callees: HashSet[string]) =
  a.callGraph[caller] = callees

proc addStackUsage*(a: var Analyzer, fn: string, su: StackUsage) =
  a.stackUsages[fn] = su

proc loadCallGraphFromFile(a: var Analyzer, path: string) =
  if not fileExists(path): return
  for line in lines(path):
    let parts = line.splitWhitespace()
    if parts.len < 2: continue
    let caller = parts[0]
    for i in 1 ..< parts.len:
      a.addCall(caller, parts[i])

proc loadStackUsageFromFile(a: var Analyzer, path: string, flags: int) =
  if not fileExists(path): return
  for line in lines(path):
    let parts = line.splitWhitespace()
    if parts.len < 2: continue
    let fn    = parts[0]
    var frame = 0i64
    try: frame = parseInt(parts[1])
    except: continue
    if frame < 0: continue
    if (flags and FlagCspOnly) != 0 and not fn.startsWith(CspPrefix):
      continue

    var su = defaultStackUsage()
    if (flags and FlagStackByUser) != 0:
      su.stackByUser = frame
    else:
      su.frameSize = frame
      var nm = initNamer()
      var entity: NamerEntity
      if parts.len >= 3 and nm.isGenerated(fn):
        try:
          su.procReserved = parseInt(parts[2])
        except: discard
    a.addStackUsage(fn, su)

proc loadFromDir(a: var Analyzer, dirPath: string) =
  if not dirExists(dirPath):
    stderr.writeLine(&"{ErrPrefix}open {dirPath} failed.")
    quit(1)

  var sfNames, cgNames: seq[string]
  for kind, name in walkDir(dirPath, relative = true):
    if kind != pcFile: continue
    if name.endsWith(StackFrameExt):
      sfNames.add(name[0 ..< name.len - StackFrameExt.len])
    elif name.endsWith(CallGraphExt):
      cgNames.add(name[0 ..< name.len - CallGraphExt.len])

  # Sort by timestamp (numeric filename prefix)
  proc byTime(a, b: string): int =
    try: cmp(parseInt(a), parseInt(b))
    except: cmp(a, b)

  sfNames.sort(byTime)
  cgNames.sort(byTime)

  let isShare = dirPath == a.options.installedPrefix & SubpathShare

  for name in cgNames:
    a.loadCallGraphFromFile(dirPath & name & CallGraphExt)
  for name in sfNames:
    let flags = if isShare: FlagCspOnly else: 0
    a.loadStackUsageFromFile(dirPath & name & StackFrameExt, flags)

proc load(a: var Analyzer) =
  if not a.options.isBuildingLibcsp:
    a.loadFromDir(a.options.installedPrefix & SubpathShare)
  a.loadFromDir(a.options.workingDir)
  if a.options.extraSuFile != "":
    a.loadStackUsageFromFile(a.options.extraSuFile, FlagStackByUser)

proc collectWrapperFuncs(a: var Analyzer): Table[int, string] =
  var nm = initNamer()
  for fn, _ in a.stackUsages:
    var entity: NamerEntity
    if not nm.parse(fn, entity): continue
    if result.hasKey(entity.id):
      stderr.writeLine(&"{ErrPrefix}duplicated process id.")
      quit(1)
    result[entity.id] = entity.name
  result

proc mustGetMaxStackSize(a: var Analyzer, name: string): int64 =
  if not a.stackUsages.hasKey(name):
    return int64(a.options.defaultStackSize)
  let su = a.stackUsages[name]
  if su.maxStackSize >= 0: su.maxStackSize
  else: int64(a.options.defaultStackSize)

proc getAnalyzingOrder(a: var Analyzer, wrappers: Table[int, string]): seq[string] =
  var order: seq[string]
  var queue = initDeque[string]()
  var visited = initHashSet[string]()

  queue.addLast(FnCspCoreProcExit)
  queue.addLast(FnExit)
  visited.incl(FnCspCoreProcExit)
  visited.incl(FnExit)

  for _, wname in wrappers:
    if wname notin visited:
      queue.addLast(wname)
      visited.incl(wname)

  # Build reversed call graph
  var rcg: Table[string, HashSet[string]]
  while queue.len > 0:
    let caller = queue.popFirst()
    if a.callGraph.hasKey(caller):
      for callee in a.callGraph[caller]:
        rcg.mgetOrPut(callee, initHashSet[string]()).incl(caller)
        if callee notin visited:
          queue.addLast(callee)
          visited.incl(callee)

  # In-degrees
  var degrees: Table[string, int]
  for node, callers in rcg:
    if node notin degrees: degrees[node] = 0
    for caller in callers:
      degrees.mgetOrPut(caller, 0).inc()

  var zero = initDeque[string]()
  for node, deg in degrees:
    if deg == 0:
      zero.addLast(node)
      if a.stackUsages.hasKey(node):
        let su = a.stackUsages[node]
        if su.stackByUser >= 0:
          a.stackUsages[node].maxStackSize = su.stackByUser
        else:
          a.stackUsages[node].maxStackSize = su.frameSize
      else:
        a.stackUsages[node] = StackUsage(maxStackSize: int64(a.options.defaultStackSize),
                                          stackByUser: -1, frameSize: -1, procReserved: -1)

  while zero.len > 0:
    let node = zero.popFirst()
    order.add(node)
    if not a.stackUsages.hasKey(node):
      a.stackUsages[node] = defaultStackUsage()
    if rcg.hasKey(node):
      for caller in rcg[node]:
        degrees[caller].dec()
        if degrees[caller] == 0:
          zero.addLast(caller)

  # Add remaining wrappers
  for _, wname in wrappers:
    order.add(wname)
    if not a.stackUsages.hasKey(wname):
      a.stackUsages[wname] = defaultStackUsage()

  order

proc genConfig(a: var Analyzer, wrappers: Table[int, string]) =
  let total = wrappers.len
  let path  = a.fs.fullPath(ConfigFileName)
  let f     = open(path, fmWrite)
  defer: f.close()

  let cpuCores    = a.options.cpuCores
  let maxThreads  = a.options.maxThreads
  let maxProcsH   = a.options.maxProcsHint

  f.writeLine("// Configure file generated by libcsp cli.")
  f.writeLine("//")
  f.writeLine("// DO NOT modify it!")
  f.writeLine("")
  f.writeLine("#include <stdlib.h>")
  f.writeLine(&"size_t csp_cpu_cores = {cpuCores};")
  f.writeLine(&"size_t csp_max_threads = {maxThreads};")
  f.writeLine(&"size_t csp_max_procs_hint = {maxProcsH};")
  f.writeLine(&"size_t csp_procs_num = {total};")
  f.write("size_t csp_procs_size[] = {")

  let pageSize = 1u64 shl 12
  for id in 0 ..< total:
    if not wrappers.hasKey(id):
      stderr.writeLine(&"{ErrPrefix}process id {id} not found")
      quit(1)
    let wname = wrappers[id]
    let size  = uint64(a.stackUsages[wname].maxStackSize)
    let pages = (size div pageSize) + (if size mod pageSize != 0: 1u64 else: 0u64)
    f.write(&"{pages * pageSize}, ")

  f.writeLine("};")

proc saveCallGraph*(a: var Analyzer) =
  let path = a.fs.genFileName(CallGraphExt)
  let f    = open(path, fmAppend)
  defer: f.close()
  for caller, callees in a.callGraph:
    if callees.len == 0: continue
    f.write(caller)
    for callee in callees:
      f.write(" " & callee)
    f.writeLine("")

proc saveStackUsage*(a: var Analyzer) =
  let path = a.fs.genFileName(StackFrameExt)
  let f    = open(path, fmAppend)
  defer: f.close()
  for fn, su in a.stackUsages:
    if su.typ == StackUsageType.Dynamic and su.frameSize < 0: continue
    f.write(&"{fn} {su.frameSize}")
    if su.procReserved > 0:
      f.write(&" {su.procReserved}")
    f.writeLine("")

proc save*(a: var Analyzer) =
  a.saveCallGraph()
  a.saveStackUsage()

proc analyze*(a: var Analyzer, options: AnalyzerOptions) =
  a.options = options
  a.fs.setWorkingDir(options.workingDir)
  a.load()

  let wrappers = a.collectWrapperFuncs()
  if wrappers.len == 0:
    a.genConfig(wrappers)
    return

  let order = a.getAnalyzingOrder(wrappers)

  for caller in order:
    if not a.stackUsages.hasKey(caller):
      a.stackUsages[caller] = defaultStackUsage()

    var su = a.stackUsages[caller]
    if su.maxStackSize >= 0: continue

    if su.stackByUser >= 0:
      a.stackUsages[caller].maxStackSize = su.stackByUser
      continue

    var maxChild = 0i64
    if a.callGraph.hasKey(caller):
      for callee in a.callGraph[caller]:
        let s = a.mustGetMaxStackSize(callee)
        if s > maxChild: maxChild = s
    a.stackUsages[caller].maxStackSize = maxChild + 8

  # Compute final proc memory sizes
  for id, wname in wrappers:
    let exitSize = a.mustGetMaxStackSize(
      if wname == "csp_main": FnExit else: FnCspCoreProcExit)

    var su = a.stackUsages[wname]
    if su.maxStackSize < exitSize:
      a.stackUsages[wname].maxStackSize = exitSize

    let cspProcTSize = 32 * 8  # sizeof(csp_proc_t)
    a.stackUsages[wname].maxStackSize +=
      su.procReserved + int64(cspProcTSize) + 8

  a.genConfig(wrappers)
