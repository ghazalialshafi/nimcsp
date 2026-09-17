# Package
version       = "0.0.1"
author        = "Ghazali"
description   = "CSP Go-style goroutines runtime in pure Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["cspcli"]

# ─── Required build flags ───────────────────────────────────────────────────
# --mm:arc is NOT optional. ARC (and ORC) do reference counting, not stack scanning,
# so they don't have this problem. See README.md "Build requirements".
const RequiredFlags = "--threads:on --mm:arc -d:useMalloc --stacktrace:off"

task build_lib, "Build libcsp":
  exec "nim c --app:lib " & RequiredFlags & " -d:release --passC:\"-D_GNU_SOURCE\" -o:libcsp.so src/csp.nim"

task build_cli, "Build cspcli":
  # --path:. is required: cspcli.nim imports plugin/{fs,namer,sa}, which
  # sit outside srcDir ("src"), and Nim doesn't search the project root by
  # default. Without this flag `nim c src/cspcli.nim` fails outright with
  # "cannot open file: plugin/fs" -- this was broken before this comment
  # was added; verify with `nimble build_cli` after changing this task.
  exec "nim c " & RequiredFlags & " --path:. -d:release -o:cspcli src/cspcli.nim"

task test, "Build and run the correctness test suite once":
  exec "bash tests/run_all.sh --quick"

task testAll, "Build and run the full test suite (correctness + stress), matching CI":
  exec "bash tests/run_all.sh"
