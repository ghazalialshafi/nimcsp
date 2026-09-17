## namer.nim
## Process name generation and parsing for the plugin.
## Equivalent to plugin/namer.hpp

import std/[strutils, strformat]
import fs

const
  CspProcPrefix*        = "csp___"
  DefaultInstalledPrefix* = "/usr/local/"
  SubpathShare*         = "share/libcsp/"

type
  NamerType* {.pure.} = enum
    Async, Sync, Timer, Other

const NamerTypeLabels* = ["async", "sync", "timer", "other"]

type
  NamerEntity* = object
    id*:   int
    name*: string
    typ*:  NamerType

  Namer* = object
    nextId*:    int
    prefix*:    string
    latestName*: string
    workingDir*: string

proc initNamer*(): Namer =
  Namer(nextId: 0, prefix: CspProcPrefix)

proc initialize*(n: var Namer, isBuildingLibcsp: bool,
                 installedPrefix, workingDir: string) =
  n.workingDir = if workingDir == "": DefaultWorkingDir else: workingDir
  n.nextId = readSession(n.workingDir & SessionName)

  if n.nextId == 0 and not isBuildingLibcsp:
    var pfx = installedPrefix
    if pfx == "": pfx = DefaultInstalledPrefix
    if not pfx.endsWith("/"): pfx.add('/')
    n.nextId = readSession(pfx & SubpathShare & SessionName)

proc currentId*(n: Namer): int = n.nextId - 1
proc currentName*(n: Namer): string = n.latestName

proc format(n: Namer, e: NamerEntity): string =
  &"{n.prefix}{NamerTypeLabels[ord(e.typ)]}_{e.id}_{e.name}"

proc nextName*(n: var Namer, fnName: string, typ: NamerType): string =
  let e = NamerEntity(id: n.nextId, name: fnName, typ: typ)
  n.latestName = n.format(e)
  inc n.nextId
  n.latestName

proc isGenerated*(n: Namer, name: string): bool =
  for label in NamerTypeLabels:
    if name.startsWith(n.prefix & label):
      return true
  false

proc parse*(n: Namer, name: string, entity: var NamerEntity): bool =
  if not n.isGenerated(name): return false
  var rest = name[n.prefix.len .. ^1]

  var typFound = false
  for i, label in NamerTypeLabels:
    if rest.startsWith(label & "_"):
      entity.typ = NamerType(i)
      rest = rest[label.len + 1 .. ^1]
      typFound = true
      break
  if not typFound: return false

  let underscore = rest.find('_')
  if underscore < 0: return false
  try:
    entity.id = parseInt(rest[0 ..< underscore])
  except: return false
  entity.name = rest[underscore + 1 .. ^1]
  true

proc save*(n: Namer) =
  let path = n.workingDir & SessionName
  writeFile(path, $n.nextId)
