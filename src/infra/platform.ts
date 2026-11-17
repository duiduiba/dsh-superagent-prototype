/**
 * The platform differences between the POSIX hosts this prototype was written for and Windows.
 *
 * Everything else in the codebase stays POSIX-shaped on POSIX, so a change here is the whole of what Windows support
 * costs: how a bare command name resolves (`PATHEXT`), how a `.cmd`/`.ps1` wrapper is started (Windows cannot start
 * either directly), how a worker shim is written (no shebang, `;` in `PATH`), and which shell runs a prepare command.
 */

import { extname, join } from 'node:path'

export const windows = process.platform === 'win32'

/** Windows PowerShell, which every supported Windows ships; the shims below call it by name. */
export const powershell = 'powershell.exe'

/**
 * Extensions a bare command name may carry, in resolution order. On POSIX a command name is the file name; on Windows
 * the shell resolves it through `PATHEXT`, so a `.cmd` wrapper is found where POSIX would find an extensionless script.
 */
export const programExtensions: readonly string[] = windows ? ['.exe', '.cmd', '.bat', '.ps1'] : ['']

/** The files a command may name, in resolution order; a name that already carries an extension resolves as itself. */
export function programFiles(file: string): string[] {
  return windows && !extname(file) ? programExtensions.map(extension => file + extension) : [file]
}

/** The same resolution inside one `PATH` directory. */
export const candidates = (directory: string, name: string): string[] => programFiles(join(directory, name))

/** A program and arguments ready for `execFile`/`spawn`, plus the options that launch needs. */
export interface Launch {
  program: string
  args: string[]
  options?: { windowsVerbatimArguments: boolean }
}

/**
 * Quotes one argument for a `cmd.exe` command line. Inside double quotes `cmd` reads spaces, `&`, `|`, `<`, `>` and
 * `^` literally; a literal `"%name%"` would still expand, which no argument this code builds contains.
 */
const cmdQuote = (token: string): string => `"${token.replaceAll('"', '""')}"`

/**
 * Rewrites a program and arguments into something this platform can start.
 *
 * `cmd` and `.bat` files are not executable without a shell, and `.ps1` files need PowerShell, so both are started
 * through their interpreter. The `cmd` command line is passed verbatim because `cmd` parses its own quotes; letting
 * the runtime quote it would escape the inner quotes that `cmd` relies on.
 */
export function launch(program: string, args: string[]): Launch {
  if (!windows) return { program, args }
  const extension = extname(program).toLowerCase()
  if (extension === '.cmd' || extension === '.bat') {
    const line = [program, ...args].map(cmdQuote).join(' ')
    return { program: process.env.ComSpec || 'cmd.exe', args: ['/d', '/s', '/c', `"${line}"`], options: { windowsVerbatimArguments: true } }
  }
  if (extension === '.ps1') {
    return { program: powershell, args: ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', program, ...args] }
  }
  return { program, args }
}

/**
 * The argv that runs a prepare command. POSIX uses `sh -c`; Windows passes the same text to PowerShell, whose own
 * parser reads it, so the operator writes the command in the shell their workers use.
 */
export function prepareShell(command: string): string[] {
  return windows
    ? [powershell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', command]
    : ['sh', '-c', command]
}

/** The file name a worker shim takes in the shim directory. */
export const shimName = (name: string): string => windows ? `${name}.cmd` : name

/**
 * The name of the shell tool DSH registers on this platform: `pwsh` on Windows, `bash` elsewhere. A tool allow list that
 * names the wrong one is refused outright, so every list that names a shell names this.
 */
export const shellTool = windows ? 'pwsh' : 'bash'

/** How a shell command spells its own wait, which the orchestrator refuses at the start of a command. */
export const sleepCommand = windows ? 'Start-Sleep|sleep' : 'sleep'
