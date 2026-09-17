## cspcli.nim
## Command-line interface for the libcsp build toolchain.
## Equivalent to plugin/cli.cpp

import std/[os, strutils, strformat, options, tables, sets]
import plugin/fs
import plugin/sa

# ─── Version / usage ──────────────────────────────────────────────────────────

const CliVersion = "0.0.2"

const CliUsage = """
Usage:
  cspcli <command> [options]

Commands:
  init:
    Initialize the environment for the building. Libcsp will create the
    working directory if it doesn't exist or otherwise clean the generated
    files left by the previous building.

    Options:
      --working-dir:
        The working directory. Default is /tmp/libcsp.

  analyze:
    Analyze the memory usages of processes and generate the configuration
    file `config.c`. Libcsp plugin will generate the function stack frame
    size to files with extension .sf and the function call graph to files
    with extension .cg. This command will analyze the memory usage of all
    processes according to these files. You can set some configurations
    with the following options:

    Options:
      --working-dir:       The working directory. Default is `/tmp/libcsp/`.
      --installed-prefix:  The value of `--prefix` in `./configure`. Default is `/usr/local/`.
      --extra-su-file:     The extra stack usage file (format: `fn size` per line).
      --default-stack-size: Default stack size for unknown functions. Default is 2KB.
      --cpu-cores:         Number of CPU cores for libcsp. Default is max.
      --max-threads:       Max threads libcsp can create. Default is 1024.
      --max-procs-hint:    Hint of max processes. Default is 100000.

  clean:
    Clear related generated files in the working directory.

    Options:
      --working-dir:  The working directory. Default is /tmp/libcsp/.

  version:
    Display the cspcli version.
"""

# ─── Command parsing ──────────────────────────────────────────────────────────

type
  Cmd = enum cmdInit, cmdAnalyze, cmdClean, cmdVersion

proc parseCmd(s: string): Option[Cmd] =
  case s
  of "init":    some(cmdInit)
  of "analyze": some(cmdAnalyze)
  of "clean":   some(cmdClean)
  of "version": some(cmdVersion)
  else:         none(Cmd)

proc parseOptions(args: openArray[string], cmd: Cmd): AnalyzerOptions =
  result = defaultOptions()
  var i = 0
  while i < args.len:
    let arg = args[i]
    if not arg.startsWith("--"):
      inc i; continue
    let eqPos = arg.find('=', 2)
    var key, val: string
    if eqPos > 0:
      key = arg[2 ..< eqPos]
      val = arg[eqPos + 1 .. ^1]
    else:
      key = arg[2 .. ^1]
      inc i
      val = if i < args.len: args[i] else: ""
    inc i

    if val == "": continue

    case key
    of "working-dir":
      result.workingDir = val
    of "installed-prefix":
      if not fs.exists(val):
        stderr.writeLine(&"{ErrPrefix}{val} doesn't exist.")
        quit(1)
      result.installedPrefix = val
    of "extra-su-file":
      if not fs.exists(val):
        stderr.writeLine(&"{ErrPrefix}{val} doesn't exist.")
        quit(1)
      result.extraSuFile = val
    of "building-libcsp":
      result.isBuildingLibcsp = val == "true"
    of "default-stack-size":
      try:
        let n = parseInt(val)
        if n > 0: result.defaultStackSize = uint(n)
      except: discard
    of "cpu-cores":
      try:
        let n = parseInt(val)
        if n > 0: result.cpuCores = uint(n)
      except: discard
    of "max-threads":
      try:
        let n = parseInt(val)
        if n > 0: result.maxThreads = uint(n)
      except: discard
    of "max-procs-hint":
      try:
        let n = parseInt(val)
        if n > 0: result.maxProcsHint = uint(n)
      except: discard
    else:
      discard

# ─── Commands ─────────────────────────────────────────────────────────────────

proc doInit(options: AnalyzerOptions) =
  var workDir = options.workingDir
  if workDir == "": workDir = DefaultWorkingDir
  if not workDir.endsWith("/"): workDir.add('/')

  if fs.exists(workDir):
    # Clean existing generated files
    for kind, name in walkDir(workDir):
      if kind != pcFile: continue
      let base = name.extractFilename()
      if base == ConfigFileName or base == SessionName or
         base.endsWith(CallGraphExt) or base.endsWith(StackFrameExt):
        removeFile(name)
  else:
    createDir(workDir)

proc doAnalyze(options: AnalyzerOptions) =
  var a = Analyzer()
  a.fs = initFilesystem(options.workingDir)
  a.stackUsages = initTable[string, StackUsage]()
  a.callGraph   = initTable[string, HashSet[string]]()
  a.analyze(options)

proc doClean(options: AnalyzerOptions) =
  var workDir = options.workingDir
  if workDir == "": workDir = DefaultWorkingDir
  if not workDir.endsWith("/"): workDir.add('/')
  if not fs.exists(workDir): return

  for kind, name in walkDir(workDir):
    if kind != pcFile: continue
    let base = name.extractFilename()
    if base == ConfigFileName or base == SessionName or
       base.endsWith(CallGraphExt) or base.endsWith(StackFrameExt):
      try: removeFile(name)
      except:
        stderr.writeLine(&"{ErrPrefix}clean failed, you may need to manually rm {name}")

# ─── main ─────────────────────────────────────────────────────────────────────

when isMainModule:
  let allArgs = commandLineParams()

  if allArgs.len == 0 or allArgs[0] in ["-h", "--help"]:
    echo CliUsage
    quit(if allArgs.len == 0: 1 else: 0)

  let cmdStr = allArgs[0]
  let cmdOpt = parseCmd(cmdStr)
  if cmdOpt.isNone():
    stderr.writeLine(&"{ErrPrefix}invalid command {cmdStr}!\n\n{CliUsage}")
    quit(1)

  let cmd  = cmdOpt.get()
  let opts = parseOptions(allArgs[1 .. ^1], cmd)

  case cmd
  of cmdInit:    doInit(opts)
  of cmdAnalyze: doAnalyze(opts)
  of cmdClean:   doClean(opts)
  of cmdVersion: echo CliVersion
