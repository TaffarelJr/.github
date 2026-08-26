#Requires -Version 7.0

<#
.SYNOPSIS
    Writes the release body for a version, from the git history.

.DESCRIPTION
    Produces two documents in one file: the release notes a reader needs to
    decide whether to upgrade, and the complete changelog folded below them.

    Reads git history only, so this behaves the same in every repo regardless
    of what the repo is written in.

.PARAMETER Version
    The version being released, used for the heading and the compare link.

.PARAMETER OutputPath
    Where to write the Markdown. Defaults to 'Changelog.md'.

.PARAMETER FromTag
    Start from this tag instead of the most recent release tag. Use it to
    rebuild notes for an earlier release.

.PARAMETER ToRef
    The commit to release. Defaults to HEAD.

.PARAMETER SummaryPath
    A file holding the prose summary to put at the top - generated, or
    hand-written. When absent, a placeholder comment is emitted instead.

.PARAMETER Repository
    The 'owner/name' used to build links. Defaults to GITHUB_REPOSITORY so a
    workflow needs to pass nothing.

.EXAMPLE
    ./scripts/New-Changelog.ps1 -Version 1.4.0

    Writes Changelog.md covering everything since the last v* tag.

.EXAMPLE
    ./scripts/New-Changelog.ps1 -Version 1.4.0 -SummaryPath summary.md

    The same, with a prose summary in place of the placeholder.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [string]$OutputPath = 'Changelog.md',

    [string]$FromTag,

    [string]$ToRef = 'HEAD',

    [string]$SummaryPath,

    [string]$Repository = $env:GITHUB_REPOSITORY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The entry script is the one place that uses -Force, so an edit to a module is
# picked up on the next run. A nested import inside a module deliberately omits
# it, because -Force removes the module and would tear it out of the scope here.
Import-Module (Join-Path $PSScriptRoot 'Common-Console.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Common-Input.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Common-Process.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'New-Changelog-Tasks.psm1') -Force

$headSha = (git rev-parse $ToRef).Trim()
$baseline = Get-ChangelogBaseline -HeadSha $headSha -FromTag $FromTag

$from = if ($baseline.Tag) {
    "$($baseline.Tag) ($($baseline.Sha.Substring(0, 7)))"
}
else { 'the start of history' }

Write-Field 'Version' $Version
Write-Field 'From' $from
Write-Field 'To' $headSha.Substring(0, 7)

$commits = @(Get-ChangelogCommit -StartSha $baseline.Sha -EndSha $headSha)
Write-Field 'Commits' $commits.Count

$summary = ''
if ($SummaryPath) {
    if (-not (Test-Path $SummaryPath)) {
        # Not fatal: a missing summary costs a placeholder, and failing the
        # release over it would be worse.
        Write-Warn "No summary at '$SummaryPath'; using the placeholder."
    }
    else {
        $summary = (Get-Content $SummaryPath -Raw).Trim()
        Write-Ok "Summary read from '$SummaryPath'"
    }
}

$lines = Format-ReleaseNote `
    -Version $Version `
    -Commits $commits `
    -Baseline $baseline `
    -Repository $Repository `
    -Summary $summary

foreach ($group in (Get-CategoryGroup $commits).Values) {
    Write-Detail "$($group.Title) ($($group.Commits.Count))"
}

Set-Content -Path $OutputPath -Value $lines -Encoding utf8NoBOM
Write-Ok "Wrote $OutputPath ($($lines.Count) lines)"
