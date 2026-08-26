#Requires -Version 7.0
<#
    Console output, shared by every script in this folder.

    Two scripts printing the same kind of thing should look identical, so the
    markers, the indentation, and the tallies live here rather than being
    reinvented per script.

    Output adapts to where it is running. Under GitHub Actions a section folds
    into a collapsible group and a failure becomes an annotation the UI can
    link to; locally the same calls produce a coloured banner.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# State
#───────────────────────────────────────────────────────────────────────────────

# Tallies for the end-of-run summary, owned by the Write-* functions
# that increment them.
$script:OkCount = 0
$script:SkipCount = 0
$script:WarnCount = 0

# Set by Write-Step, so a failure banner can name where things went wrong.
$script:CurrentStep = ''
$script:CurrentStepTitle = ''

$script:Rule = '─' * 72

$script:InCI = ($env:GITHUB_ACTIONS -eq 'true')

function Test-CIEnvironment {
    <#
    .SYNOPSIS
        Reports whether this is running under GitHub Actions.
    #>
    return $script:InCI
}

#───────────────────────────────────────────────────────────────────────────────
# Outcome markers
#───────────────────────────────────────────────────────────────────────────────

# One marker per outcome, so the log reads consistently:
#   ✅ succeeded   ⏭️ already done   ⚠️ warning   ❌ failed   ℹ️ neutral note
function Write-Ok {
    param([string]$Msg)
    $script:OkCount++
    Write-Host "  ✅ $Msg" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Msg)
    $script:SkipCount++
    Write-Host "  ⏭️  $Msg" -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Msg)
    $script:WarnCount++
    # An Actions warning annotation also surfaces in the run summary, so a
    # warning is not lost in a thousand lines of log.
    if ($script:InCI) { Write-Host "::warning::$Msg" }
    else { Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow }
}

function Write-Err {
    param([string]$Msg)
    if ($script:InCI) { Write-Host "::error::$Msg" }
    else { Write-Host "  ❌ $Msg" -ForegroundColor Red }
}

function Write-Info {
    param([string]$Msg)
    Write-Host "  ℹ️  $Msg" -ForegroundColor Gray
}

# Indented continuation line, for detail belonging to the marker above it.
function Write-Detail {
    param([string]$Msg)
    Write-Host "       $Msg" -ForegroundColor DarkGray
}

# Aligned label/value pair, for a run header.
function Write-Field {
    # An empty -Label is allowed:
    # it renders a continuation line under the field above.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [string]$Value
    )

    Write-Host ("  ·  {0,-18}{1}" -f $Label, $Value) -ForegroundColor Gray
}

#───────────────────────────────────────────────────────────────────────────────
# Sections
#───────────────────────────────────────────────────────────────────────────────

function Write-Step {
    <#
    .SYNOPSIS
        Starts a numbered step, recording it so a failure can name it.
    #>
    param(
        [Parameter(Mandatory)][string]$Number,
        [Parameter(Mandatory)][string]$Title
    )
    $script:CurrentStep = $Number
    $script:CurrentStepTitle = $Title
    $head = "═══ STEP $Number · $Title "
    Write-Host ""
    $pad = '═' * [Math]::Max(0, 72 - $head.Length)
    Write-Host ($head + $pad) -ForegroundColor Cyan
}

function Write-SectionStart {
    <#
    .SYNOPSIS
        Opens a named section, collapsible when running under Actions.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $script:CurrentStepTitle = $Name
    if ($script:InCI) { Write-Host "::group::$Name" }
    else {
        Write-Host ''
        Write-Host "── $Name " -NoNewline -ForegroundColor Blue
        Write-Host ('─' * [Math]::Max(0, 74 - $Name.Length)) -ForegroundColor Blue
    }
}

function Write-SectionEnd {
    <#
    .SYNOPSIS
        Closes the section opened by Write-SectionStart.
    #>
    if ($script:InCI) { Write-Host '::endgroup::' }
}

function Invoke-Section {
    <#
    .SYNOPSIS
        Runs a body inside a named section, closing it even on failure.
    .DESCRIPTION
        The group has to be closed before an annotation is written, or the
        annotation ends up folded inside the collapsed section where nobody
        will see it.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    Write-SectionStart $Name
    try { & $Body }
    finally { Write-SectionEnd }
}

#───────────────────────────────────────────────────────────────────────────────
# Summaries
#───────────────────────────────────────────────────────────────────────────────

function Show-Summary {
    <#
    .SYNOPSIS
        Prints a one-line tally, so the end of a run reads at a glance.
    #>
    Write-Host ""
    $tally = '  {0} ok · {1} already done · {2} warning(s)'
    $counts = $script:OkCount, $script:SkipCount, $script:WarnCount
    Write-Host ($tally -f $counts) -ForegroundColor Gray
}

function Show-Failure {
    <#
    .SYNOPSIS
        Renders a terminating error as a readable banner,
        instead of a raw PowerShell dump.
    .DESCRIPTION
        Reports which step failed, the message, the offending line,
        and the script stack trace.
    .PARAMETER Activity
        What failed, named in the banner.
    .PARAMETER Resumable
        Says the run can simply be repeated. True for scaffolding, which is
        idempotent; false for anything that is not.
    #>
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [string]$Activity = 'RUN',
        [switch]$Resumable
    )
    Write-Host ""
    Write-Host $script:Rule -ForegroundColor Red
    $where = if ($script:CurrentStep -ne '') {
        " — STEP $($script:CurrentStep) · $($script:CurrentStepTitle)"
    }
    else { '' }
    Write-Host " ❌ $Activity FAILED$where" -ForegroundColor Red
    Write-Host $script:Rule -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($ErrorRecord.Exception.Message)" -ForegroundColor Red

    $inv = $ErrorRecord.InvocationInfo
    if ($inv -and $inv.ScriptName) {
        Write-Host ""
        $at = "$(Split-Path -Leaf $inv.ScriptName):$($inv.ScriptLineNumber)"
        Write-Host "  at $at" -ForegroundColor DarkGray
        if ($inv.Line) { Write-Detail $inv.Line.Trim() }
    }
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Host ""
        Write-Host "  Stack trace:" -ForegroundColor DarkGray
        foreach ($line in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
            if ($line.Trim()) { Write-Detail $line.Trim() }
        }
    }
    Show-Summary
    if ($Resumable) {
        Write-Host ""
        Write-Host '  Nothing rolled back. Re-run to resume where it left off.' `
            -ForegroundColor Yellow
    }
    Write-Host ""
}

function Add-JobSummary {
    <#
    .SYNOPSIS
        Appends Markdown to the Actions run summary, if there is one.
    .DESCRIPTION
        A no-op locally, so a caller does not have to test for CI first.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Markdown)

    if (-not $env:GITHUB_STEP_SUMMARY) { return }
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Markdown -Encoding utf8NoBOM
}

#───────────────────────────────────────────────────────────────────────────────
# Failure
#───────────────────────────────────────────────────────────────────────────────

function Assert-ExitCode {
    <#
    .SYNOPSIS
        Turns a non-zero exit code into a terminating error, annotated in CI.
    .DESCRIPTION
        A native command failing does not stop PowerShell, whatever
        $ErrorActionPreference says, so every external call has to be checked
        explicitly or a failure is silently reported as success.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$ExitCode = $LASTEXITCODE
    )
    if ($ExitCode -eq 0) { return }

    $message = "$Name failed with exit code $ExitCode"
    if ($script:InCI) {
        # Close the group first, or the annotation is hidden inside it.
        Write-Host '::endgroup::'
        Write-Host "::error title=$Name::$message"
    }
    throw $message
}

Export-ModuleMember -Function @(
    'Test-CIEnvironment'
    'Write-Ok'
    'Write-Skip'
    'Write-Warn'
    'Write-Err'
    'Write-Info'
    'Write-Detail'
    'Write-Field'
    'Write-Step'
    'Write-SectionStart'
    'Write-SectionEnd'
    'Invoke-Section'
    'Show-Summary'
    'Show-Failure'
    'Add-JobSummary'
    'Assert-ExitCode'
)
