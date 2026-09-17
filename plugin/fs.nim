## fs.nim
## Filesystem helpers for the cspcli tool.
## Equivalent to plugin/fs.hpp

import std/[os, times, strutils, strformat]

const
  DefaultWorkingDir* = "/tmp/libcsp/"
  SessionName*       = ".session"
  ErrPrefix*         = "libcsp error: "
  CallGraphExt*      = ".cg"
  StackFrameExt*     = ".sf"
  ConfigFileName*    = "config.c"
  CspPrefix*         = "csp_"
  FnExit*            = "exit"
  FnCspCoreProcExit* = "csp_core_proc_exit"

type
  Filesystem* = object
    workingDir*: string

proc initFilesystem*(workingDir = DefaultWorkingDir): Filesystem =
  var d = workingDir
  if d == "": d = DefaultWorkingDir
  if not d.endsWith("/"): d.add('/')
  Filesystem(workingDir: d)

proc setWorkingDir*(fs: var Filesystem, dir: string) =
  var d = dir
  if d == "": d = DefaultWorkingDir
  if not d.endsWith("/"): d.add('/')
  fs.workingDir = d

proc exists*(path: string): bool = fileExists(path) or dirExists(path)

proc openFile*(path: string, mode: FileMode): File =
  var f: File
  if not open(f, path, mode):
    stderr.writeLine(&"{ErrPrefix}failed to open {path}")
    quit(1)
  f

proc genFileName*(fs: Filesystem, ext: string): string =
  &"{fs.workingDir}{int(epochTime())}{ext}"

proc fullPath*(fs: Filesystem, subpath: string): string =
  var s = subpath
  if s.startsWith("/"): s = s[1 .. ^1]
  fs.workingDir & s

proc readSession*(path: string): int =
  if not fileExists(path): return 0
  try:
    let content = readFile(path).strip()
    if content.len > 0: parseInt(content)
    else: 0
  except: 0
