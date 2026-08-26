#Requires -Version 7.0
<#
    Console output, and whether the run changed anything.

    Two scripts printing the same kind of thing should look identical, so the
    markers, the indentation and the tallies live here, and no script has to
    re-derive them. There is deliberately no untallied success marker: a
    closing line printed after the summary is the caller's own.

    Write-Doing/Write-Done report a single step's progress on one line -
    "attempting this ... outcome" - so a run reads as a debug trace even
    when nothing goes wrong. Every other writer here closes a line left
    open by Write-Doing first, so a warning or a failure mid-step can never
    land on the same line as what it interrupted.

    The change counter lives here too, because it is read at the end of a run
    alongside the tally - but it is not one of them. Reporting an outcome and
    changing state are separate events.

    Scaffolding itself is driven by hand on a developer's machine, and a leaf
    repo deletes scripts/ outright; the only CI these modules ever see is
    their own test workflow. So nothing here adapts its output for a runner -
    the test runner pins the console encoding, and that is all it takes.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# State and constants
#───────────────────────────────────────────────────────────────────────────────

# Owned by the Write-* functions that increment them.
$script:OkCount = 0
$script:SkipCount = 0
$script:WarnCount = 0

# Not one of the printed tallies: did this run change anything?
# Gates the work only worth doing when something actually changed.
$script:ChangeCount = 0

# Set by Write-Step, so a failure banner can name where things went wrong.
$script:CurrentStepLabel = ''

# Set by Write-Doing, cleared by Write-Done or by any other writer closing
# it on its behalf. True only while a line is printed with no trailing
# newline yet.
$script:LineOpen = $false

# 72, not 80: a rule that reaches the margin looks like wrapped text, and the
# banner has to stay legible when a terminal adds its own gutter.
$script:RuleWidth = 72
$script:Rule = '─' * $script:RuleWidth

#───────────────────────────────────────────────────────────────────────────────
# Change tracking
#───────────────────────────────────────────────────────────────────────────────

function Add-Change {
    <#
    .SYNOPSIS
        Records that this run changed real state, not just reported on it.
    #>
    $script:ChangeCount++
}

function Get-ChangeCount {
    <#
    .SYNOPSIS
        Returns how many changes this run made, so a caller can tell a no-op
        run from one that did work.
    #>
    return $script:ChangeCount
}

#───────────────────────────────────────────────────────────────────────────────
# Messages
#───────────────────────────────────────────────────────────────────────────────

function Format-MessageText {
    <#
    .SYNOPSIS
        Returns a message safe to print, substituting blank ones.
    .DESCRIPTION
        Not exported. A message assembled from interpolation can come out
        empty, and a logging call must never be the thing that ends a run - so
        an empty one renders visibly rather than throwing. Show-Failure applies
        the same rule to an empty failure reason, in its own wording.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return '(no message)' }
    return $Message
}

function Close-OpenLine {
    <#
    .SYNOPSIS
        Ends a line left open by Write-Doing, if one is open.
    .DESCRIPTION
        Not exported. Every other writer in this module calls it first, so a
        warning, a skip, or a failure that interrupts a "Doing" line starts
        its own line instead of running on to the end of it.
    #>
    if (-not $script:LineOpen) { return }
    Write-Host ''
    $script:LineOpen = $false
}

# The number of trailing spaces differs between markers on purpose, and is not
# a typo. A bare emoji renders two columns wide; one carrying a U+FE0F
# variation selector renders narrower and needs a second space. Keep them
# aligned when changing a marker, or every message below it shifts.
function Write-Ok {
    <#
    .SYNOPSIS
        Reports that something was done.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    Close-OpenLine
    $script:OkCount++
    Write-Host "  ✅ $(Format-MessageText $Message)" -ForegroundColor Green
}

function Write-Skip {
    <#
    .SYNOPSIS
        Reports that something was already done, so nothing changed.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    Close-OpenLine
    $script:SkipCount++
    Write-Host "  ⏭️  $(Format-MessageText $Message)" -ForegroundColor DarkGray
}

function Write-Warn {
    <#
    .SYNOPSIS
        Reports something worth attention that does not stop the run.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    Close-OpenLine
    $script:WarnCount++
    Write-Host "  ⚠️  $(Format-MessageText $Message)" -ForegroundColor Yellow
}

function Write-Info {
    <#
    .SYNOPSIS
        Reports a neutral note, neither an outcome nor a problem.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    Close-OpenLine
    Write-Host "  ℹ️  $(Format-MessageText $Message)" -ForegroundColor Gray
}

# Two columns past the marker text above it - see the marker note above, since
# this indent has to move with it.
function Write-Detail {
    <#
    .SYNOPSIS
        Adds a continuation line, indented under the message above it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    Close-OpenLine
    Write-Host "       $(Format-MessageText $Message)" -ForegroundColor DarkGray
}

function Write-Field {
    <#
    .SYNOPSIS
        Prints an aligned label and value, for a run header.
    .PARAMETER Label
        Budgeted at 18 columns; a longer label pushes its value out of the
        column. May be empty, which prints the value alone in the value
        column, continuing the field above.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [string]$Value
    )

    Close-OpenLine
    Write-Host ("  ·  {0,-18}{1}" -f $Label, $Value) -ForegroundColor Gray
}

#───────────────────────────────────────────────────────────────────────────────
# Progress
#───────────────────────────────────────────────────────────────────────────────

function Write-Doing {
    <#
    .SYNOPSIS
        Announces what a step is about to attempt, on a line left open.
    .DESCRIPTION
        Pair it with Write-Done. Anything printed in between - Write-Warn,
        Write-Detail, another Write-Doing, a throw reaching Show-Failure -
        closes this line first instead of running on to the end of it.
    #>
    param([Parameter(Mandatory)][string]$Message)

    Close-OpenLine
    Write-Host "  ▶ $Message ..." -NoNewline -ForegroundColor Cyan
    $script:LineOpen = $true
}

function Write-Done {
    <#
    .SYNOPSIS
        Closes the line opened by Write-Doing, with its outcome.
    .DESCRIPTION
        Falls back to Write-Ok/Write-Skip - a fresh line, not a continuation -
        when no Write-Doing is open, so a caller does not have to track that
        itself.
    .PARAMETER Skip
        Marks the outcome as unchanged rather than done, the same distinction
        Write-Skip makes on its own line.
    #>
    param(
        [string]$Message,
        [switch]$Skip
    )

    if (-not $PSBoundParameters.ContainsKey('Message')) {
        $Message = if ($Skip) { 'already done' } else { 'done' }
    }

    if (-not $script:LineOpen) {
        if ($Skip) { Write-Skip $Message } else { Write-Ok $Message }
        return
    }

    $script:LineOpen = $false
    if ($Skip) { $script:SkipCount++ } else { $script:OkCount++ }
    $color = if ($Skip) { 'DarkGray' } else { 'Green' }
    Write-Host " $(Format-MessageText $Message)" -ForegroundColor $color
}

#───────────────────────────────────────────────────────────────────────────────
# Steps
#───────────────────────────────────────────────────────────────────────────────

function Write-Step {
    <#
    .SYNOPSIS
        Starts a numbered step, recording it so a failure can name it.
    .DESCRIPTION
        Steps do not nest: a second call replaces the first.
    .PARAMETER Number
        A string, not a number, so a step can be '10' or '3a' without the
        signature changing.
    #>
    param(
        [Parameter(Mandatory)][string]$Number,
        [Parameter(Mandatory)][string]$Title
    )

    Close-OpenLine
    $script:CurrentStepLabel = " — STEP $Number · $Title"

    Write-Host ""
    $head = "═══ STEP $Number · $Title "
    $pad = '═' * [Math]::Max(0, $script:RuleWidth - $head.Length)
    Write-Host ($head + $pad) -ForegroundColor Cyan
}

function Clear-Step {
    <#
    .SYNOPSIS
        Forgets the current step, so a later failure is not blamed on it.
    .DESCRIPTION
        Call once, after the last step - not after each one; there is no
        per-step teardown. Without it, anything that fails afterwards reports
        a step that had already succeeded.
    #>
    $script:CurrentStepLabel = ''
}

#───────────────────────────────────────────────────────────────────────────────
# Summaries
#───────────────────────────────────────────────────────────────────────────────

function Show-Summary {
    <#
    .SYNOPSIS
        Prints a one-line tally, so the end of a run reads at a glance.
    #>
    Close-OpenLine
    Write-Host ""
    $tally = '  {0} ok · {1} already done · {2} warning(s)'
    $counts = @(
        $script:OkCount
        $script:SkipCount
        $script:WarnCount
    )

    Write-Host ($tally -f $counts) -ForegroundColor Gray
}

function Show-Banner {
    <#
    .SYNOPSIS
        Prints a rule, the given lines, and a closing rule.
    .DESCRIPTION
        A blank line before, none after: what follows a banner differs by
        caller, so the spacing after it is the caller's to choose.
    .PARAMETER Line
        One console line each, printed as given - so indent them to taste.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Line,
        [string]$Color = 'Cyan'
    )

    Close-OpenLine
    Write-Host ""
    Write-Host $script:Rule -ForegroundColor $Color
    foreach ($text in $Line) { Write-Host $text -ForegroundColor $Color }
    Write-Host $script:Rule -ForegroundColor $Color
}

function Write-FailureReason {
    <#
    .SYNOPSIS
        Prints the error's message, every line indented into the banner.
    .DESCRIPTION
        Not exported. Every line, not just the first: a wrapped git or gh
        failure folds the command's own stderr into the message, and an
        unindented line breaks out of the banner. An empty message is possible
        too - `throw ''` and `throw "$unsetVar"` both produce one - and would
        leave no reason at all, so the exception's type stands in.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $reason = $ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = "$($ErrorRecord.Exception.GetType().Name) with no message"
    }

    foreach ($line in ($reason -split "`r?`n")) {
        Write-Host "  $line" -ForegroundColor Red
    }
}

function Write-FailureLocation {
    <#
    .SYNOPSIS
        Prints the file, line, and source text the error came from, when known.
    .DESCRIPTION
        Not exported. Silent when the record carries no script location - an
        error thrown from the prompt, for one - rather than printing a blank.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $invocation = $ErrorRecord.InvocationInfo
    if (-not $invocation -or -not $invocation.ScriptName) { return }

    Write-Host ""
    $file = Split-Path -Leaf $invocation.ScriptName
    Write-Host "  At ${file}:$($invocation.ScriptLineNumber)" -ForegroundColor DarkGray
    if ($invocation.Line) { Write-Detail $invocation.Line.Trim() }
}

function Write-FailureStack {
    <#
    .SYNOPSIS
        Prints the script stack trace, one frame per line, when there is one.
    .DESCRIPTION
        Not exported. Blank frames are dropped rather than printed as empty
        detail lines.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    if (-not $ErrorRecord.ScriptStackTrace) { return }

    Write-Host ""
    Write-Host "  Stack trace:" -ForegroundColor DarkGray
    foreach ($line in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
        if ($line.Trim()) { Write-Detail $line.Trim() }
    }
}

function Show-Failure {
    <#
    .SYNOPSIS
        Renders a terminating error as a readable banner,
        instead of a raw PowerShell dump.
    .DESCRIPTION
        Reports the step that was running when there was one, the message, and
        the failing line and stack trace when the error carries them.

        Prints the closing tally itself, so a caller must not also call
        Show-Summary. It deliberately leaves the warning tally alone: that
        counts problems the run carried on past, and this one did not.

        The ErrorRecord is typed, because this runs from the entry script's
        trap: anything it cannot render would replace the banner with the raw
        dump it exists to prevent, so a wrong argument has to fail at bind
        time instead.
    .PARAMETER Activity
        What failed, named in the banner. Rendered as given, so pass it in the
        case you want to see.
    .PARAMETER Resumable
        Pass it only when every step is idempotent, so re-running is genuinely
        safe. Without it the banner ends without guidance, and a caller that
        needs to say something about the state it left behind must print its
        own line.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Activity = 'RUN',
        [switch]$Resumable
    )

    Close-OpenLine
    Show-Banner -Color Red -Line " ❌ $Activity FAILED$($script:CurrentStepLabel)"
    Write-Host ""
    Write-FailureReason -ErrorRecord $ErrorRecord
    Write-FailureLocation -ErrorRecord $ErrorRecord
    Write-FailureStack -ErrorRecord $ErrorRecord

    Show-Summary
    if ($Resumable) {
        Write-Host ""
        $hint = '  No repo changes were rolled back. Re-run to resume.'
        Write-Host $hint -ForegroundColor Yellow
    }

    Write-Host ""
}

Export-ModuleMember -Function @(
    'Write-Ok'
    'Write-Skip'
    'Write-Warn'
    'Write-Info'
    'Write-Detail'
    'Write-Field'
    'Write-Doing'
    'Write-Done'
    'Show-Banner'
    'Write-Step'
    'Clear-Step'
    'Show-Summary'
    'Show-Failure'
    'Add-Change'
    'Get-ChangeCount'
)
