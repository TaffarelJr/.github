#Requires -Version 7.0
<#
    Tests for Common-GitHub-Actions.psm1: dispatching Template Sync and
    waiting on it, against a stubbed gh that plays out one scenario per case.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-Process', 'Common-Git', 'Common-Checklist',
    'Common-GitHub', 'Common-GitHub-Actions'

$ownerRepo = 'TaffarelJr/demo'

# A failed poll only throws after this many in a row, so a scenario that
# exercises that path needs a deadline with room for them at one poll a second.
$unreadableBudget = (& (Get-Module Common-GitHub-Actions) { $script:MaxUnreadablePolls }) + 2

# The stub answers by the KIND of gh call - listing runs, dispatching, viewing
# a run, listing pull requests - from a plan the case supplies. A kind the plan
# leaves out succeeds silently. A plan entry may be a scriptblock, for an
# answer that changes from one call to the next.
function New-PlanHandler {
    param([Parameter(Mandatory)][hashtable]$Plan)

    return {
        param([string[]]$a)
        $kind = 'other'
        if ($a.Count -ge 2) {
            $kind = switch ("$($a[0]) $($a[1])") {
                'run list' { 'runList' }
                'workflow run' { 'dispatch' }
                'run view' { 'runView' }
                'pr list' { 'prList' }
                default { 'other' }
            }
        }

        if (-not $Plan.ContainsKey($kind)) { return $null }
        $reply = $Plan[$kind]
        if ($reply -is [scriptblock]) { $reply = & $reply }
        return $reply
    }.GetNewClosure()
}

# The run list as the sync sees it: only the earlier run at first, then the
# new one as well.
function New-RunListSequence {
    param([string[]]$First = @('111'), [string[]]$Later = @('222', '111'), [int]$LaterExit = 0)

    # A hashtable, not a counter variable: assigning to a captured variable
    # inside a closure makes a new local copy, so a plain $calls++ never sticks.
    $state = @{ Calls = 0 }
    return {
        $state.Calls++
        if ($state.Calls -eq 1) { return @{ Exit = 0; Out = $First } }
        return @{ Exit = $LaterExit; Out = $Later }
    }.GetNewClosure()
}

function Invoke-Sync {
    param([Parameter(Mandatory)][hashtable]$Plan, [int]$TimeoutSeconds = 2)

    Set-GhStub -Handler (New-PlanHandler -Plan $Plan)
    $start = Get-Narration { Start-TemplateSync -OwnerRepo $ownerRepo }
    $handle = if ($start.Output.Count) { $start.Output[0] } else { $null }
    $wait = Get-Narration {
        Wait-TemplateSync -OwnerRepo $ownerRepo -Handle $handle `
            -TimeoutSeconds $TimeoutSeconds -PollSeconds 1
    }

    return [pscustomobject]@{ Handle = $handle; Lines = @($start.Lines) + @($wait.Lines) }
}

function Test-Said {
    param([Parameter(Mandatory)][pscustomobject]$Result, [Parameter(Mandatory)][string]$Pattern)

    return [bool]($Result.Lines -match $Pattern)
}

Write-TestSection '1. the happy path'
# Act
$r = Invoke-Sync @{
    runList  = New-RunListSequence
    dispatch = @{ Exit = 0 }
    runView  = @{ Exit = 0; Out = @('completed|success') }
    prList   = @{ Exit = 0; Out = @() }
}

# Assert
Assert-That 'reports a clean sync' (Test-Said $r 'ran clean, with nothing to sync') `
    ($r.Lines -join ' | ')
Assert-That 'waited on the NEW run, not the pre-existing one' (Test-Said $r 'run 222')
Assert-That 'no warning on the happy path' (-not (Test-Said $r 'Could not|did not|still'))
Assert-That 'dispatches on the branch Common-Git owns' (Test-GhCall "--ref $(Get-DefaultBranch)") `
((Get-GhCall) -join ' | ')

Write-TestSection '2. the runs cannot be listed before the dispatch'
# Act
$r = Invoke-Sync @{
    runList  = @{ Exit = 1; Out = @('HTTP 401: Bad credentials') }
    dispatch = @{ Exit = 0 }
}

# Assert
Assert-That 'still dispatches' (Test-Said $r 'Dispatching Template Sync')
Assert-That 'says it will not wait' (Test-Said $r 'could not list the earlier runs')
Assert-That 'returns no handle' ($null -eq $r.Handle)

Write-TestSection '3. the runs become unreadable during the wait'
# Act
$r = Invoke-Sync -TimeoutSeconds $unreadableBudget @{
    runList  = New-RunListSequence -Later @('network unreachable') -LaterExit 1
    dispatch = @{ Exit = 0 }
}

# Assert
Assert-That 'blames the unreadable call, not a timeout' `
    (Test-Said $r 'Could not check Template Sync') `
    ($r.Lines -join ' | ')
Assert-That 'does NOT claim the run never started' (-not (Test-Said $r 'did not start')) `
    ($r.Lines -join ' | ')

Write-TestSection '4. the run view is unreadable'
# Act
$r = Invoke-Sync -TimeoutSeconds $unreadableBudget @{
    runList  = New-RunListSequence
    dispatch = @{ Exit = 0 }
    runView  = @{ Exit = 1; Out = @('HTTP 502') }
}

# Assert
Assert-That 'blames the unreadable call' (Test-Said $r 'Could not check Template Sync') `
    ($r.Lines -join ' | ')
Assert-That 'no empty-status message' (-not (Test-Said $r "still '' after|still  after")) `
    ($r.Lines -join ' | ')

Write-TestSection '5. a genuinely stuck run still reports a timeout'
# Act
$r = Invoke-Sync @{
    runList  = New-RunListSequence
    dispatch = @{ Exit = 0 }
    runView  = @{ Exit = 0; Out = @('in_progress|') }
}

# Assert
Assert-That 'names the status it really saw' (Test-Said $r "still 'in_progress' after")

Write-TestSection '6. the pull request check fails'
# Act
$r = Invoke-Sync @{
    runList  = New-RunListSequence
    dispatch = @{ Exit = 0 }
    runView  = @{ Exit = 0; Out = @('completed|success') }
    prList   = @{ Exit = 1; Out = @('HTTP 403') }
}

# Assert
Assert-That 'does not claim a clean sync' (-not (Test-Said $r 'ran clean'))
Assert-That 'says the pull requests could not be checked' `
    (Test-Said $r 'pull requests could not be checked')

Write-TestSection '7. the sync opened a pull request'
# Act
$r = Invoke-Sync @{
    runList  = New-RunListSequence
    dispatch = @{ Exit = 0 }
    runView  = @{ Exit = 0; Out = @('completed|success') }
    prList   = @{ Exit = 0; Out = @('#7 Merge changes from template repo') }
}

# Assert
Assert-That 'reports the pull request' (Test-Said $r 'opened 1 pull request')
Assert-That 'shows its title' (Test-Said $r '#7 Merge changes')
Assert-That 'does not also claim a clean sync' (-not (Test-Said $r 'ran clean'))

Write-TestSection '8. a failed dispatch relays what gh said'
# Act
$r = Invoke-Sync @{
    runList  = @{ Exit = 0; Out = @('111') }
    dispatch = @{ Exit = 1; Out = @('could not find any workflows named template-sync.yml') }
}

# Assert
Assert-That "relays gh's own message" (Test-Said $r 'could not find any workflows')
Assert-That 'does not guess a cause' (-not (Test-Said $r 'still be registering'))

Write-TestSection '9. the contract and the module surface'
Assert-Throws '-Handle rejects a non-hashtable at bind time' -Match 'Handle' `
    { Wait-TemplateSync -OwnerRepo 'x/y' -Handle 'not-a-hashtable' -TimeoutSeconds 1 }

$exported = (Get-Command -Module Common-GitHub-Actions).Name
foreach ($n in 'Get-SyncPullRequest', 'Wait-TemplateSyncRun', 'Test-TemplateSyncClean') {
    Assert-That "$n stays private" ($n -notin $exported)
}

foreach ($n in 'Start-TemplateSync', 'Wait-TemplateSync', 'Get-WorkflowRunId',
    'Wait-WorkflowRunStart', 'Wait-WorkflowRunFinish') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
