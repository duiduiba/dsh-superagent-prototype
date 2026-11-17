# 009 Windows

dsh-superagent was written for POSIX hosts: its service manager needs `tmux`, `ps`, and SIGINT, its worker shims are
`#!/bin/sh` scripts, and it passes `PATH` through the `env` command. This document records what a Windows host changes
and what stays the same, reading only as far as [006 Deployment](006-deployment.md) and
[007 Architecture](007-architecture.md). Everything below is in this checkout; nothing waits for an upstream release.

## What a Windows host changes

| Where | POSIX | Windows |
| --- | --- | --- |
| Resolving a configured CLI (`src/infra/platform.ts`) | the name itself | `PATHEXT`: `.exe`, `.cmd`, `.bat`, `.ps1` |
| Starting a configured CLI | `execFile` of the path | a `.cmd` through `cmd.exe /d /s /c`, a `.ps1` through PowerShell, an `.exe` as before |
| Worker shims (`src/infra/environment.ts`) | `#!/bin/sh` that strips its own directory from `PATH` and `exec`s the CLI | `gh.cmd` that strips its directory with three literal `PATH` substitutions and `call`s the CLI |
| Probing an account (`src/deployment.ts`) | `env PATH=… <cli> …` | the `PATH` entry merged into the child environment, since Windows has no `env` |
| Prepare command (`src/executor/dsh.ts`) | `sh -c <command>` | `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command <command>` |
| Service manager | `scripts/dsh-superagent` (tmux, `ps`, SIGINT) | `scripts/dsh-superagent.ps1` (PID file, `Win32_Process`, pause-then-terminate) |

The Policy, Tickets, Executors, prompts, panel, and Sources are unchanged: they never touch a shell.

## Prerequisites

Node.js 22.19+ or 24+, pnpm, git 2.47 or later (its bundled `sh` runs the `!` credential helper), Python 3.8+ only for
the POSIX service manager (the PowerShell one needs none), and the GitHub CLI. `gh` is the one CLI here that must be an
`.exe` or reachable through `PATHEXT`.

Git for Windows is required, not optional: the agent's git configuration names its credential helper as
`!<cli> auth git-credential`, and git runs a `!` helper through `sh`, which only Git for Windows provides.

## Setup

Follow `SETUP.md` as written, with these differences:

- **No Feishu unless you also install `lark-cli` for Windows**; the GitHub Source needs nothing extra.
- **The prepared workspace is a PowerShell command.** Answer the checkout question with something such as
  `git -C C:\src\widgets worktree add $env:DSH_SUPERAGENT_DIR -b "agent/$env:DSH_SUPERAGENT_NAME"`.
- **Start and stop with the PowerShell script**:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dsh-superagent.ps1 status
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dsh-superagent.ps1 start
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dsh-superagent.ps1 stop
  ```

  It keeps the exit codes of the POSIX script: 0 normal, 1 stopped or duplicated or unreachable, 2 a component reports
  an error, 3 waiting for setup. `start` and `restart` also take `-Timeout`, `stop` takes `-StopTimeout`, and a
  monitoring task passes `-RespectStop`.
- **The hourly check** is a scheduled task running `... status`; if it exits nonzero and `-RespectStop` says the
  operator stopped the service deliberately, the task runs `start -RespectStop`.

## What differs in behaviour

- **Stopping is not graceful in the POSIX sense.** Windows has no SIGINT for a process another console started, so
  `stop` terminates the process. Running Executor Sessions end with it, and a Ticket they held waits for its next pass.
  Keep `StopTimeout` generous anyway: the script waits that long for the process to disappear and reports a timeout
  rather than killing twice. It deliberately does not pause processing first: a pause is a persisted setting, and one
  written here would survive the restart and leave every later start unable to accept work.
- **A started service is one process.** The script records the DSH PID it finds by command line, so `status` also
  notices an instance started outside the script, and a second start is refused.
- **File modes are not a boundary.** `0o600` and `0o700` are ignored; the state directory is protected by the operator's
  profile ACL. Do not put the state directory somewhere other users can read.
- **`.cmd` shims forward arguments with `%*`.** An argument holding `%` reaches the CLI unchanged; one holding `"` is
  passed through as written. The GitHub and Feishu arguments this code builds hold neither.
- **Dependencies install in a hoisted layout.** `.npmrc` sets `node-linker=hoisted`, because Node on Windows does not
  always resolve the directory junctions of pnpm's default layout: vitest then fails to load its own configuration with
  `Cannot find package '@vitest/utils'`. The layout does not change the lockfile, so a POSIX host installs the same
  dependencies.

## Tests

`pnpm check` runs the typecheck, the tests, and the build on Windows, as on POSIX; it needs `pnpm` on `PATH` because the
script calls its own steps through it. Suites whose stand-in CLIs are `#!/bin/sh` scripts, or that need `tmux`, `ps`,
SIGINT, or a symlink privilege, skip themselves on Windows and say so where they do:

- `tests/service-script.spec.ts` — the POSIX service manager; `scripts/dsh-superagent.ps1` is exercised against a real
  service instead.
- `tests/deployment.spec.ts` — it links a directory and runs `#!/bin/sh` stand-ins.
- parts of `tests/environment.spec.ts`, `tests/commands.spec.ts`, and `tests/sources.spec.ts` (the Feishu event consumer),
  and one prompt-file test that needs a temporary directory on the repository's own drive.

`tests/windows.spec.ts` covers the Windows layer on every platform, and runs the generated `.cmd` shims for real where
`cmd.exe` exists.
