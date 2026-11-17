/**
 * Windows platform layer: how a command name resolves, how a `.cmd` or `.ps1` wrapper is started, which shell runs a
 * prepare command, and how worker shims are written. The POSIX shapes stay covered by the suites beside this file,
 * which need a POSIX shell, `ps`, and `tmux`; this one runs everywhere and executes the generated shims where it can.
 */
import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { candidates, launch, prepareShell, programFiles, shimName, windows } from '../src/infra/platform.ts'
import { workerBin, writeEnvironment } from '../src/infra/environment.ts'
import { executable, notificationScope, pathVariable } from '../src/deployment.ts'
import { testDeployment } from './fixtures/deployment.ts'

const exec = promisify(execFile)
let dir: string
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'windows-')) })
afterEach(() => { rmSync(dir, { recursive: true, force: true }) })

describe('command resolution', () => {
  it('takes the platform\'s extension for a bare name and leaves a named file alone', () => {
    const files = programFiles(join(dir, 'gh'))
    if (windows) {
      // Windows resolves a bare name through PATHEXT, in the order the shell tries them.
      expect(files).toEqual(['.exe', '.cmd', '.bat', '.ps1'].map(extension => join(dir, 'gh') + extension))
    } else {
      expect(files).toEqual([join(dir, 'gh')])
    }
    expect(programFiles(join(dir, 'gh.cmd'))).toEqual([join(dir, 'gh.cmd')])
  })
  it('searches each PATH directory with the same extensions', () => {
    expect(candidates(dir, 'gh')).toEqual(programFiles(join(dir, 'gh')))
  })
  it('finds a `.cmd` wrapper by its bare name', () => {
    writeFileSync(join(dir, 'gh-bot.cmd'), '@echo off\r\n')
    expect(executable('gh-bot', dir)).toBe(join(dir, 'gh-bot.cmd'))
  })
  it('rejects a relative path that names a directory', () => {
    expect(() => executable('bin/gh', dir)).toThrow('must be a command name or an absolute path')
  })
  it('names PATH the way this platform spells it', () => {
    expect(Object.keys(process.env)).toContain(pathVariable)
    expect(pathVariable.toUpperCase()).toBe('PATH')
  })
})

describe('the agent token\'s notification scope', () => {
  const output = (scopes: string) => `HTTP/2.0 200 OK\r\nX-Oauth-Scopes: ${scopes}\r\nContent-Type: application/json\r\n\r\n{"login":"agent-bot","id":7}\n`
  it('reads the scopes GitHub reports for the token', () => {
    expect(notificationScope(output('gist, notifications, repo'))).toBe(true)
    expect(notificationScope(output('gist, repo, workflow'))).toBe(false)
    expect(notificationScope(output('NOTIFICATIONS, repo'))).toBe(true)
  })
  it('leaves a token that reports no scopes alone, as a fine-grained token does', () => {
    expect(notificationScope('{"login":"agent-bot","id":7}\n')).toBeUndefined()
    expect(notificationScope('HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{}')).toBeUndefined()
  })
})

describe('launching a configured CLI', () => {  it('starts a `.cmd` wrapper through the command interpreter, quoting for cmd rather than for the runtime', () => {
    const target = launch('C:\\tools\\gh bot.cmd', ['api', 'user'])
    if (!windows) {
      expect(target).toEqual({ program: 'C:\\tools\\gh bot.cmd', args: ['api', 'user'] })
      return
    }
    expect(target.program.toLowerCase()).toContain('cmd')
    // /s makes cmd strip the outer quotes, so the line keeps the quotes that name the program and its arguments.
    expect(target.args.slice(0, 3)).toEqual(['/d', '/s', '/c'])
    expect(target.args[3]).toBe('""C:\\tools\\gh bot.cmd" "api" "user""')
    expect(target.options).toEqual({ windowsVerbatimArguments: true })
  })
  it('starts a `.ps1` wrapper with PowerShell and passes its arguments as they are', () => {
    const target = launch('C:\\tools\\gh-bot.ps1', ['api', 'user'])
    if (!windows) {
      expect(target).toEqual({ program: 'C:\\tools\\gh-bot.ps1', args: ['api', 'user'] })
      return
    }
    expect(target.program).toBe('powershell.exe')
    expect(target.args).toEqual(['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', 'C:\\tools\\gh-bot.ps1', 'api', 'user'])
  })
  it('starts an executable without a shell', () => {
    expect(launch('C:\\tools\\gh.exe', ['api'])).toEqual({ program: 'C:\\tools\\gh.exe', args: ['api'] })
  })
})

describe('prepare command shell', () => {
  it('runs the command in the shell the workers use', () => {
    const argv = prepareShell('git worktree add "$DSH_SUPERAGENT_DIR"')
    if (windows) {
      expect(argv.slice(0, 5)).toEqual(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass'])
      expect(argv[5]).toBe('-Command')
      expect(argv[6]).toBe('git worktree add "$DSH_SUPERAGENT_DIR"')
    } else {
      expect(argv).toEqual(['sh', '-c', 'git worktree add "$DSH_SUPERAGENT_DIR"'])
    }
  })
})

describe('worker shims', () => {
  it('names them so the platform\'s shell resolves the bare command', () => {
    expect(shimName('gh')).toBe(windows ? 'gh.cmd' : 'gh')
    expect(shimName('lark-cli')).toBe(windows ? 'lark-cli.cmd' : 'lark-cli')
  })
  it('writes a shim that strips its own directory from PATH and calls the real CLI', async () => {
    await writeEnvironment(testDeployment({ stateDir: dir, feishu: undefined }), ['personal-gh'])
    const bin = workerBin(dir)
    const files = ['gh', 'lark-cli', 'personal-gh'].map(name => shimName(name))
    for (const file of files) expect(() => readFileSync(join(bin, file), 'utf8')).not.toThrow()
    const gh = readFileSync(join(bin, shimName('gh')), 'utf8')
    expect(gh).toContain(testDeployment().github.cli)
    if (windows) {
      expect(gh.startsWith('@echo off\r\n')).toBe(true)
      expect(gh).toContain(`set "PATH=%PATH:${bin};=%"`)
      expect(gh).toContain(`call "${testDeployment().github.cli}" %*`)
    } else {
      expect(gh.startsWith('#!/bin/sh\n')).toBe(true)
      expect(gh).toContain('exec')
    }
  })
  it('owns what it wrote: a second run replaces its shims but refuses a foreign file', async () => {
    await writeEnvironment(testDeployment({ stateDir: dir }), [])
    await writeEnvironment(testDeployment({ stateDir: dir }), [])
    writeFileSync(join(workerBin(dir), 'notes.txt'), 'notes\n')
    await expect(writeEnvironment(testDeployment({ stateDir: dir }), [])).rejects.toThrow('was not written by dsh-superagent')
  })
  it.skipIf(!windows)('fails a blocked command with the agent\'s login when the shell runs the shim', async () => {
    await writeEnvironment(testDeployment({ stateDir: dir, feishu: undefined }), ['personal-gh'])
    const file = join(workerBin(dir), shimName('personal-gh'))
    const target = launch(file, [])
    const failure = await exec(target.program, target.args, target.options).catch((error: unknown) => error)
    const error = failure as { code?: number; stderr?: string }
    expect(error.code).toBe(1)
    expect(error.stderr).toContain('personal-gh is blocked in this installation; use gh, which acts as agent-bot.')
  })
  it.skipIf(!windows)('runs the real CLI through the shim with the shim directory off PATH', async () => {
    // A stand-in CLI that prints the PATH it received, so the shim's own directory must not appear.
    const cli = join(dir, 'real-gh.cmd')
    writeFileSync(cli, '@echo off\r\necho %PATH%\r\n')
    await writeEnvironment(testDeployment({ stateDir: dir, github: { ...testDeployment().github, cli }, feishu: undefined }), [])
    const target = launch(join(workerBin(dir), shimName('gh')), [])
    const { stdout } = await exec(target.program, target.args, target.options)
    expect(String(stdout).toLowerCase()).not.toContain(workerBin(dir).toLowerCase())
  })
})
