#Requires -Version 7.0

<#
.SYNOPSIS
    Runs every *.Tests.ps1 in this folder, each in its own PowerShell process,
    and exits with the number of files that failed.

.DESCRIPTION
    Discovery is by pattern, so a template layer adds coverage for its own
    module by dropping a New-Repo-<NN>-<slug>.Tests.ps1 beside these - nothing
    here is edited. A fresh process per file keeps module state and the gh and
    Read-Host stubs from leaking between files, so each file only has to reset
    between its own cases.

    A file's own output is shown only when it fails, unless -ShowOutput.

.PARAMETER Filter
    A wildcard over the file name, without the .Tests.ps1 suffix.

.EXAMPLE
    ./Run-Tests.ps1

.EXAMPLE
    ./Run-Tests.ps1 -Filter Common-Git -ShowOutput
#>
[CmdletBinding()]
param(
    [string]$Filter = '*',
    [switch]$ShowOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The files print UTF-8 (the console markers, non-ASCII paths under test);
# without this a Windows console decodes their output as its legacy code page.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$files = Get-ChildItem -Path $PSScriptRoot -Filter "$Filter.Tests.ps1" -File |
    Sort-Object Name
if (-not $files) {
    Write-Host "No test file matches '$Filter.Tests.ps1' in $PSScriptRoot" -ForegroundColor Yellow
    exit 1
}

$pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$total = [System.Diagnostics.Stopwatch]::StartNew()
$results = foreach ($file in $files) {
    $name = $file.Name -replace '\.Tests\.ps1$'
    Write-Host "▶ $name ..." -NoNewline -ForegroundColor Cyan
    if ($ShowOutput) { Write-Host '' }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $output = @(& $pwsh -NoProfile -NonInteractive -File $file.FullName 2>&1 |
            ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    $clock.Stop()

    # The file's own tally line; absent when it crashed before reaching one.
    $tally = @($output -match '^(\d+) passed, (\d+) failed$') | Select-Object -Last 1
    $passed = if ($tally) { [int]($tally -replace ' passed.*') } else { 0 }
    $failed = if ($tally) { [int]($tally -replace '.* passed, ' -replace ' failed') } else { 0 }
    $crashed = -not $tally -or ($exitCode -ne 0 -and $failed -eq 0)

    $seconds = '{0,6:N1}s' -f $clock.Elapsed.TotalSeconds
    $verdict = if ($crashed) { "💥 crashed (exit $exitCode)" }
    elseif ($exitCode -ne 0) { "❌ $passed passed, $failed failed" }
    else { "✅ $passed passed" }
    $color = if ($exitCode -eq 0) { 'Green' } else { 'Red' }
    Write-Host " $verdict  $seconds" -ForegroundColor $color

    if ($ShowOutput -or $exitCode -ne 0) {
        foreach ($line in $output) { Write-Host "    $line" }
    }

    [pscustomobject]@{
        Name     = $name
        Passed   = $passed
        Failed   = $failed
        Crashed  = $crashed
        ExitCode = $exitCode
    }
}

$total.Stop()
$failedFiles = @($results | Where-Object { $_.ExitCode -ne 0 })
$summary = '{0} file(s) · {1} passed · {2} failed · {3} crashed · {4:m\:ss}' -f @(
    $results.Count
    ($results | Measure-Object Passed -Sum).Sum
    ($results | Measure-Object Failed -Sum).Sum
    @($results | Where-Object Crashed).Count
    $total.Elapsed
)

$color = if ($failedFiles) { 'Red' } else { 'Green' }
Write-Host "`n$summary" -ForegroundColor $color
exit $failedFiles.Count
