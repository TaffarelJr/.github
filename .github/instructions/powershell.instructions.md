---
applyTo: "**/*.{ps1,psm1,psd1}"
description: PowerShell conventions
---

# PowerShell

- Open every file with `#Requires -Version 7.0`,
  then a **blank line** before any comment-based help.
  Help adjacent to another comment is ignored, which silently breaks `-?`.
- Set `Set-StrictMode -Version Latest`
  and `$ErrorActionPreference = 'Stop'` in every module.
  Module scope does not inherit the caller's preference.
  Without the second line, a failing cmdlet is non-terminating,
  and the next `Write-Ok` reports a success that never happened.
- Name functions `Verb-Noun` using an approved verb (`Get-Verb`).
  Skip decorative prefixes; the noun should carry the meaning.
- Give every function comment-based help: `.SYNOPSIS` always,
  then `.DESCRIPTION` and `.PARAMETER` only where they add something.
  Add `.EXAMPLE` only where the call isn't obvious.
- Phrase `.SYNOPSIS` as a third-person verb phrase, matching what
  `Get-Help` shows for a built-in cmdlet: "Returns the...", "Writes the...".
  Never a bare noun phrase.
- **One command per statement.** Don't chain a pipeline across continuation
  lines: assign the first command's result to a variable, then filter or
  sort it in the next statement. Hoist a long argument array into a
  variable too. The formatter de-dents pipeline continuations, so a wrapped
  pipeline ends up looking like separate statements anyway.
- When a call is too long for one line, break at parameter boundaries and
  put each parameter on its own continuation line.
- Pass arguments to native commands as an explicit array —
  `& git @('-C', $path, 'status')`.
  Loose tokens such as `-C` bind as PowerShell parameters instead,
  silently and without an error.
- After deliberately tolerating a failed native command,
  reset `$global:LASTEXITCODE` so a later check doesn't see a phantom failure.
- **git writes progress and status to stderr even when it succeeds**, which
  PowerShell surfaces as an error and which aborts the rest of a compound
  command. Run git steps as separate statements, and judge them by
  `$LASTEXITCODE`.
- **`(?m)$` does not match before a CRLF line ending** - the `\r` is in the
  way. Prefer `[^\r\n]` and `[ \t]` over `.` and `\s`, and `\r?$` when an
  anchor is genuinely needed. A bare `.` matches `\r`, so a careless replace
  quietly converts the file to LF.
- **`Split-Path -Parent` returns a backslash path.** Normalise it with
  `-replace '\\', '/'` before joining it to a forward-slash relative path,
  or `..` resolution eats the whole prefix instead of one segment.
- Section breaks are three lines — a rule, the title, a rule —
  followed by a blank line.
- CRLF line endings, UTF-8 without a BOM (see [.editorconfig][editorConfigFile]).

## Scaffolding scripts

If this repo has a `scripts/New-Repo-Helpers.psm1`,
read [scripts/README.md][scriptsFile] before touching anything in there.
`New-Repo-Helpers.psm1` and `New-Repo.ps1` are inherited verbatim by every layer,
and must stay byte-identical across them;
layer-specific behaviour belongs in an additive `Helpers-<NN>-<slug>.psm1`.

<!-- Source Code URIs (alphabetical by file hierarchy) -->

[editorConfigFile]: ../../.editorconfig
[scriptsFile]: ../../scripts/README.md
