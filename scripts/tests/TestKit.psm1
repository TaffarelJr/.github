#Requires -Version 7.0
<#
    The harness every *.Tests.ps1 beside this file shares: assertions and the
    pass/fail tally, temp folders, console capture, module (re)loading, and the
    stubs that stand in for gh and Read-Host.

    A test file imports this, imports the modules it exercises through
    Import-ScriptModule, runs its cases, and ends with `exit (Complete-TestRun)`.
    Run-Tests.ps1 gives each file its own pwsh, so nothing here has to be undone
    between files - only between the cases within one.

    Inherited by merge, so keep it identical at every layer:
    a layer's test file defines any helper of its own locally.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScriptsRoot = Split-Path -Parent $PSScriptRoot
$script:PassCount = 0
$script:FailCount = 0
$script:TestRoots = [System.Collections.Generic.List[string]]::new()

#───────────────────────────────────────────────────────────────────────────────
# Modules under test
#───────────────────────────────────────────────────────────────────────────────

function Get-ScriptsRoot {
    <#
    .SYNOPSIS
        Returns the scripts/ folder the modules under test live in.
    #>
    return $script:ScriptsRoot
}

function Import-ScriptModule {
    <#
    .SYNOPSIS
        Imports the named scripts/ modules into the global scope, replacing any
        copy already loaded.
    .DESCRIPTION
        -Global, because the modules find each other by name at call time, and
        one imported into this module's own scope would be invisible to them.
        Importing again is also the one way to reset a module's private state
        between cases, since none of them exports a reset.
    #>
    param([Parameter(Mandatory)][string[]]$Name)

    foreach ($module in $Name) {
        Import-Module (Join-Path $script:ScriptsRoot "$module.psm1") -Force -Global
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Assertions
#───────────────────────────────────────────────────────────────────────────────

function Write-TestSection {
    <#
    .SYNOPSIS
        Prints a heading for the group of cases that follows.
    #>
    param([Parameter(Mandatory)][string]$Title)

    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Assert-That {
    <#
    .SYNOPSIS
        Records one pass or fail, printing the detail only on a fail.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        $script:PassCount++
        Write-Host "  PASS  $Name" -ForegroundColor Green
        return
    }

    $script:FailCount++
    Write-Host "  FAIL  $Name" -ForegroundColor Red
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor Red }
}

function Assert-Equal {
    <#
    .SYNOPSIS
        Records whether two values are equal as strings, case-sensitively,
        showing both on a fail.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Expected,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Actual
    )

    Assert-That $Name ("$Actual" -ceq "$Expected") "expected '$Expected', got '$Actual'"
}

function Assert-Throws {
    <#
    .SYNOPSIS
        Asserts that the action throws, with a message matching -Match.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Match = '.'
    )

    try {
        $null = & $Action
    }
    catch {
        Assert-That $Name ($_.Exception.Message -match $Match) $_.Exception.Message
        return
    }

    Assert-That $Name $false 'it did not throw'
}

function Complete-TestRun {
    <#
    .SYNOPSIS
        Removes what the file created, prints the tally, and returns the
        failure count for the file to `exit` with.
    #>
    Remove-GhStub
    Remove-ReadHostStub
    foreach ($root in $script:TestRoots) { Remove-TestFolder -Path $root }
    $script:TestRoots.Clear()

    $color = if ($script:FailCount) { 'Red' } else { 'Green' }
    Write-Host "`n$($script:PassCount) passed, $($script:FailCount) failed" -ForegroundColor $color
    return $script:FailCount
}

#───────────────────────────────────────────────────────────────────────────────
# Temp folders
#───────────────────────────────────────────────────────────────────────────────

function New-TestRoot {
    <#
    .SYNOPSIS
        Creates an empty temp folder for this test file, replacing one left
        behind by an earlier run, and removes it again in Complete-TestRun.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[\w.-]+$')][string]$Name)

    $root = Join-Path ([System.IO.Path]::GetTempPath()) 'new-repo-tests' $Name
    Remove-TestFolder -Path $root
    $resolved = New-TestFolder -Path $root
    $script:TestRoots.Add($resolved)
    return $resolved
}

function New-TestFolder {
    <#
    .SYNOPSIS
        Creates a folder, parents included, and returns its full path.
    #>
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    return (Resolve-Path -LiteralPath $Path).Path
}

function Remove-TestFolder {
    <#
    .SYNOPSIS
        Deletes a folder, retrying while something still holds a file in it.
    #>
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        }
        catch { Start-Sleep -Milliseconds (100 * $attempt) }
    }

    throw "Could not remove '$Path'"
}

#───────────────────────────────────────────────────────────────────────────────
# Console capture
#───────────────────────────────────────────────────────────────────────────────

function Get-Narration {
    <#
    .SYNOPSIS
        Runs an action and returns what it printed separately from what it
        returned.
    .DESCRIPTION
        Common-Console prints through Write-Host, which lands on the
        information stream, so `6>&1` interleaves those records with the
        action's real output. This splits them back apart, and renders the
        printed lines the way a terminal shows them: a Write-Doing left open and
        the Write-Done that completes it come back as ONE line.
    .OUTPUTS
        Output - the action's pipeline output, always an array.
        Lines  - the printed lines, always an array of strings.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lineOpen = $false
    $output = @(& $Action 6>&1 | ForEach-Object {
            if ($_ -isnot [System.Management.Automation.InformationRecord]) { return $_ }

            $data = $_.MessageData
            if ($lineOpen) { $lines[$lines.Count - 1] += "$data" } else { $lines.Add("$data") }
            $lineOpen = $data -is [System.Management.Automation.HostInformationMessage] -and
            $data.NoNewLine
        })

    return [pscustomobject]@{ Output = $output; Lines = @($lines) }
}

function Get-ConsoleCounter {
    <#
    .SYNOPSIS
        Reads one of Common-Console's tallies: Ok, Skip, Warn, or Change.
    .DESCRIPTION
        Only Change has a public accessor (Get-ChangeCount); the others are
        read from the module's scope, which is what a test needs to assert that
        a warning was actually counted rather than merely printed.
    #>
    param([Parameter(Mandatory)][ValidateSet('Ok', 'Skip', 'Warn', 'Change')][string]$Name)

    $module = Get-Module Common-Console
    return & $module { param($n) Get-Variable -Name "${n}Count" -Scope Script -ValueOnly } $Name
}

function Get-ManualItem {
    <#
    .SYNOPSIS
        Returns the items Common-Checklist has queued so far, always as an array.
    #>
    $items = & (Get-Module Common-Checklist) { $script:ManualItems }
    return , @($items)
}

#───────────────────────────────────────────────────────────────────────────────
# Stubs
#───────────────────────────────────────────────────────────────────────────────

# A function shadows an executable of the same name, and a module's command
# lookup falls through to the global scope, so a global function intercepts
# every gh or Read-Host call the modules make. The stubs keep their state in
# global variables for the same reason: the functions run in the global scope,
# where this module's own variables are out of reach.

function Set-GhStub {
    <#
    .SYNOPSIS
        Installs the gh stub if it is not already, gives it a new handler, and
        clears the calls it has recorded.
    .DESCRIPTION
        The handler receives the argv as a string array and returns a hashtable
        with Exit (the exit code) and, optionally, Out (the lines to print).
        Returning nothing at all means "exit 0, print nothing".
    #>
    param([Parameter(Mandatory)][scriptblock]$Handler)

    $global:GhStub = @{
        Handler = $Handler
        Calls   = [System.Collections.Generic.List[string]]::new()
    }

    if (Get-Command -Name gh -CommandType Function -ErrorAction SilentlyContinue) { return }

    function global:gh {
        $argv = [string[]]@($args)
        $global:GhStub.Calls.Add($argv -join ' ')
        $reply = & $global:GhStub.Handler $argv
        if ($null -eq $reply) { $reply = @{} }
        $global:LASTEXITCODE = if ($reply.ContainsKey('Exit')) { [int]$reply.Exit } else { 0 }
        if ($reply.ContainsKey('Out')) { $reply.Out | ForEach-Object { $_ } }
    }
}

function Get-GhCall {
    <#
    .SYNOPSIS
        Returns every gh argv recorded since the stub was last set, one string
        each, always as an array.
    #>
    return , [string[]]$global:GhStub.Calls
}

function Test-GhCall {
    <#
    .SYNOPSIS
        Reports whether any recorded gh argv matches the pattern.
    #>
    param([Parameter(Mandatory)][string]$Pattern)

    return [bool](@($global:GhStub.Calls) -match $Pattern)
}

function Remove-GhStub {
    <#
    .SYNOPSIS
        Uninstalls the gh stub, so the real gh is reachable again.
    #>
    Remove-Item -Path function:global:gh -ErrorAction SilentlyContinue
    Remove-Variable -Name GhStub -Scope Global -ErrorAction SilentlyContinue
}

function Set-ReadHostAnswer {
    <#
    .SYNOPSIS
        Installs the Read-Host stub if it is not already, and queues the
        answers it will give: one per prompt, an empty string once they run out.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()]
        [string[]]$Answer
    )

    $global:ReadHostQueue = [System.Collections.Generic.Queue[string]]::new([string[]]$Answer)
    if (Get-Command -Name Read-Host -CommandType Function -ErrorAction SilentlyContinue) { return }

    function global:Read-Host {
        param(
            [Parameter(Position = 0)][string]$Prompt,
            [switch]$AsSecureString,
            [switch]$MaskInput
        )

        $answer = ''
        if ($global:ReadHostQueue.Count -gt 0) { $answer = $global:ReadHostQueue.Dequeue() }
        if (-not $AsSecureString) { return $answer }

        $secure = [System.Security.SecureString]::new()
        foreach ($char in $answer.ToCharArray()) { $secure.AppendChar($char) }
        return $secure
    }
}

function Remove-ReadHostStub {
    <#
    .SYNOPSIS
        Uninstalls the Read-Host stub, so the real cmdlet is reachable again.
    #>
    Remove-Item -Path function:global:Read-Host -ErrorAction SilentlyContinue
    Remove-Variable -Name ReadHostQueue -Scope Global -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function @(
    'Get-ScriptsRoot'
    'Import-ScriptModule'
    'Write-TestSection'
    'Assert-That'
    'Assert-Equal'
    'Assert-Throws'
    'Complete-TestRun'
    'New-TestRoot'
    'New-TestFolder'
    'Remove-TestFolder'
    'Get-Narration'
    'Get-ConsoleCounter'
    'Get-ManualItem'
    'Set-GhStub'
    'Get-GhCall'
    'Test-GhCall'
    'Remove-GhStub'
    'Set-ReadHostAnswer'
    'Remove-ReadHostStub'
)
