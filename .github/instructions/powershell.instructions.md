---
applyTo: "**/*.{ps1,psm1,psd1}"
description: PowerShell conventions
---

# PowerShell

- Open every file with `#Requires -Version 7.0`,
  then a **blank line** before any comment-based help.
  Help adjacent to another comment is ignored, which silently breaks `-?`.
- Set `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`
  in every module.
  Module scope does not inherit the caller's preference, so without the
  second line a failing cmdlet is non-terminating and the next `Write-Ok`
  reports a success that never happened.
- Name functions `Verb-Noun` using an approved verb (`Get-Verb`).
  Skip decorative prefixes; the noun should carry the meaning.
- Give every function comment-based help: `.SYNOPSIS` always,
  then `.DESCRIPTION` and `.PARAMETER` only where they add something.
  Add `.EXAMPLE` only where the call isn't obvious.
- Pass arguments to native commands as an explicit array —
  `& git @('-C', $path, 'status')`.
  Loose tokens such as `-C` bind as PowerShell parameters instead,
  silently and without an error.
- After deliberately tolerating a failed native command,
  reset `$global:LASTEXITCODE` so a later check doesn't see a phantom
  failure.
- Section breaks are three lines — a rule, the title, a rule —
  followed by a blank line.
- CRLF line endings, UTF-8 without a BOM
  (see [.editorconfig][editorConfigFile]).

## Scaffolding scripts

If this repo has a `scripts/Helpers.psm1`,
read [scripts/README.md][scriptsFile] before touching anything in there.
`Helpers.psm1` and `New-Repo.ps1` are inherited verbatim by every template
layer and must stay byte-identical across them;
layer-specific behavior belongs in an additive `Helpers-<NN>-<slug>.psm1`.

<!-- Source Code URIs (alphabetical by file hierarchy) -->

[editorConfigFile]: ../../.editorconfig
[scriptsFile]: ../../scripts/README.md
