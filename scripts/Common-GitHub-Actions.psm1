#Requires -Version 7.0
<#
    Dispatching a GitHub Actions workflow and waiting for the result.

    A dispatch returns nothing identifying, so the new run is found afterwards
    by diffing the workflow's run ids against those that existed before.
    Waiting then means polling, and reporting WHY a run failed rather than
    only that it did.

    Polling has to tolerate a failed call, but it must never mistake one for
    an answer: every gh read here goes through Common-GitHub's Invoke-GhRead,
    an unreadable poll is counted, and enough of them in a row ends the wait
    with that as the reason instead of a timeout.

    The first half is generic - any workflow, any repo. The second is the one
    workflow this scaffolding dispatches: Template Sync.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Constants
#───────────────────────────────────────────────────────────────────────────────

# Both owned by TaffarelJr/.actions, and both have to agree with it: the
# workflow name is also what ties the snapshot, the dispatch and the poll
# together, so one character of difference between them costs a full timeout
# and a 'did not start' report on a perfectly healthy run.
$script:TemplateSyncWorkflow = 'template-sync.yml'
$script:TemplateSyncBranch = 'template-sync'

# Enough consecutive unreadable polls to call it: three at five seconds is
# fifteen, short enough to be useful and long enough to ride out one blip.
$script:MaxUnreadablePolls = 3

#───────────────────────────────────────────────────────────────────────────────
# Workflow runs
#───────────────────────────────────────────────────────────────────────────────

function Get-WorkflowRunId {
    <#
    .SYNOPSIS
        Returns the workflow's most recent run ids, newest first,
        or $null if they could not be read.
    .DESCRIPTION
        Used to tell a run we just dispatched apart from earlier ones, because
        `gh workflow run` does not report the id it created.

        Capped at 20, which is always enough: the dispatched run is the newest,
        and the workflow's concurrency group prevents a burst of others
        arriving ahead of it.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Workflow
    )

    $result = Invoke-GhRead -Arguments @(
        'run', 'list'
        '--repo', $OwnerRepo
        '--workflow', $Workflow
        '--limit', '20'
        '--json', 'databaseId'
        '--jq', '.[].databaseId'
    )

    if (-not $result.Ok) { return $null }

    # The leading comma keeps a single id an array on the way out, so a caller
    # can still tell it apart from $null by counting.
    return , @($result.Output | Where-Object { $_ })
}

function Wait-WorkflowRunStart {
    <#
    .SYNOPSIS
        Waits for a dispatched run to appear, and returns its id.
    .DESCRIPTION
        A dispatch returns nothing identifying it, and the run does not exist
        the instant the dispatch returns - so the new run is whichever id was
        not there beforehand. $null means it never appeared within the
        deadline; too many unreadable polls throws instead, because 'never
        appeared' would be a guess.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Workflow,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PriorRunId,
        [Parameter(Mandatory)][datetime]$Deadline,
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$PollSeconds
    )

    Write-Detail 'waiting for the run to appear'
    $unreadable = 0
    while ((Get-Date) -lt $Deadline) {
        $now = Get-WorkflowRunId -OwnerRepo $OwnerRepo -Workflow $Workflow
        if ($null -eq $now) {
            $unreadable++
            if ($unreadable -ge $script:MaxUnreadablePolls) {
                throw "Could not list $Workflow runs ($unreadable attempts in a row failed)"
            }
        }
        else {
            $unreadable = 0
            $fresh = @($now | Where-Object { $_ -notin $PriorRunId })
            if ($fresh) { return ($fresh | Select-Object -First 1) }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return $null
}

function Wait-WorkflowRunFinish {
    <#
    .SYNOPSIS
        Polls a run until it completes, and reports how it ended.
    .DESCRIPTION
        Status is what the run was last seen as - so a caller can tell a
        timeout ('in_progress') from a finish ('completed') without a second
        call. Too many unreadable polls throws, rather than letting a status
        observed once early stand as the state at the deadline.
    .OUTPUTS
        [hashtable] @{ Status; Conclusion }
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$RunId,
        [Parameter(Mandatory)][datetime]$Deadline,
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$PollSeconds
    )

    $status = ''
    $conclusion = ''
    $unreadable = 0
    while ((Get-Date) -lt $Deadline) {
        $result = Invoke-GhRead -Arguments @(
            'run', 'view', $RunId
            '--repo', $OwnerRepo
            '--json', 'status,conclusion'
            '--jq', '.status + "|" + (.conclusion // "")'
        )

        $raw = ($result.Output -join '').Trim()
        if ($result.Ok -and $raw -match '^(?<s>[^|]*)\|(?<c>.*)$') {
            $unreadable = 0
            $status = $Matches['s']
            $conclusion = $Matches['c']
            if ($status -eq 'completed') { break }
        }
        else {
            $unreadable++
            if ($unreadable -ge $script:MaxUnreadablePolls) {
                throw "Could not read run $RunId ($unreadable attempts in a row failed)"
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return @{ Status = $status; Conclusion = $conclusion }
}

#───────────────────────────────────────────────────────────────────────────────
# Template Sync
#───────────────────────────────────────────────────────────────────────────────

function Start-TemplateSync {
    <#
    .SYNOPSIS
        Dispatches the Template Sync workflow, and returns the runs that
        already existed so Wait-TemplateSync can spot the new one.
    .DESCRIPTION
        Returns @{ PriorRunId = <ids> } on success, and $null when there is no
        point waiting - either the dispatch failed, or the earlier runs could
        not be listed, which would leave the new run indistinguishable from a
        nightly one. Either way it has already said so; pass the result
        straight to Wait-TemplateSync.
    #>
    param([Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo)

    Write-Doing 'Dispatching Template Sync'

    # Taken before the dispatch, or the new run is in it too.
    $before = Get-WorkflowRunId -OwnerRepo $OwnerRepo -Workflow $script:TemplateSyncWorkflow
    $result = Invoke-GhRead -Arguments @(
        'workflow', 'run', $script:TemplateSyncWorkflow
        '--repo', $OwnerRepo
        '--ref', (Get-DefaultBranch)
    )

    if (-not $result.Ok) {
        Write-Warn 'Could not dispatch Template Sync'
        foreach ($line in $result.Output) {
            if ("$line".Trim()) { Write-Detail "$line".Trim() }
        }

        Write-Detail "run it from https://github.com/$OwnerRepo/actions"
        return $null
    }

    Add-Change
    Write-Done
    if ($null -eq $before) {
        Write-Warn 'Could not list the earlier runs, so not waiting for this one'
        Write-Detail "check https://github.com/$OwnerRepo/actions"
        return $null
    }

    return @{ PriorRunId = $before }
}

function Get-SyncPullRequest {
    <#
    .SYNOPSIS
        Returns the open pull requests on the sync branch, as "#<n> <title>",
        or $null if they could not be read.
    .DESCRIPTION
        Not exported. $null rather than an empty list on failure, because the
        caller reads emptiness as 'nothing to sync' and says so out loud.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    $result = Invoke-GhRead -Arguments @(
        'pr', 'list'
        '--repo', $OwnerRepo
        '--head', $script:TemplateSyncBranch
        '--state', 'open'
        '--json', 'number,title'
        '--jq', '.[] | "#\(.number) \(.title)"'
    )

    if (-not $result.Ok) { return $null }
    return , @($result.Output | Where-Object { $_ })
}

function Wait-TemplateSyncRun {
    <#
    .SYNOPSIS
        Waits for the dispatched Template Sync run to appear and finish, and
        returns its id and URL if it succeeded.
    .DESCRIPTION
        Not exported. $null on every other outcome - never appeared, could not
        be checked, still running at the deadline, or finished as anything but
        success - each already reported as a warning naming where to look.
    #>
    param(
        [Parameter(Mandatory)][string]$OwnerRepo,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PriorRunId,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][int]$PollSeconds
    )

    $runUrl = "https://github.com/$OwnerRepo/actions"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    try {
        $runId = Wait-WorkflowRunStart -OwnerRepo $OwnerRepo `
            -Workflow $script:TemplateSyncWorkflow -PriorRunId $PriorRunId `
            -Deadline $deadline -PollSeconds $PollSeconds
        if (-not $runId) {
            Write-Warn 'Template Sync did not start within the timeout'
            Write-Detail "check $runUrl"
            return $null
        }

        $runUrl = "https://github.com/$OwnerRepo/actions/runs/$runId"
        Write-Detail "run $runId - waiting for it to finish"
        $result = Wait-WorkflowRunFinish -OwnerRepo $OwnerRepo -RunId $runId `
            -Deadline $deadline -PollSeconds $PollSeconds
    }
    catch {
        Write-Warn "Could not check Template Sync - $($_.Exception.Message)"
        Write-Detail $runUrl
        return $null
    }

    if ($result.Status -ne 'completed') {
        Write-Warn "Template Sync was still '$($result.Status)' after ${TimeoutSeconds}s"
        Write-Detail $runUrl
        return $null
    }

    if ($result.Conclusion -ne 'success') {
        Write-Warn "Template Sync finished as '$($result.Conclusion)' - needs a look"
        Write-Detail $runUrl
        return $null
    }

    return @{ RunId = $runId; Url = $runUrl }
}

function Test-TemplateSyncClean {
    <#
    .SYNOPSIS
        Reports whether a successful Template Sync run found nothing to sync.
    .DESCRIPTION
        Not exported. Success criterion #2: a freshly scaffolded repo is
        already a descendant of its template, so the merge has nothing to
        apply. A pull request here means the new repo's tree diverges from the
        template in some way scaffolding did not account for - worth looking
        at by hand.
    #>
    param(
        [Parameter(Mandatory)][string]$OwnerRepo,
        [Parameter(Mandatory)][string]$RunUrl
    )

    $prs = Get-SyncPullRequest -OwnerRepo $OwnerRepo
    if ($null -eq $prs) {
        Write-Warn 'Template Sync passed, but its pull requests could not be checked'
        Write-Detail "check https://github.com/$OwnerRepo/pulls"
        return
    }

    if ($prs.Count -gt 0) {
        Write-Warn "Template Sync opened $($prs.Count) pull request(s)"
        Write-Detail 'a fresh repo should have nothing to sync; review these:'
        foreach ($pr in $prs) { Write-Detail $pr }
        Write-Detail "https://github.com/$OwnerRepo/pulls"
        return
    }

    Write-Done 'Template Sync ran clean, with nothing to sync'
    Write-Detail $RunUrl
}

function Wait-TemplateSync {
    <#
    .SYNOPSIS
        Waits for the dispatched Template Sync run, then checks it did nothing.
    .DESCRIPTION
        Success means BOTH that the run passed AND that it opened no pull
        request. Never throws: a broken sync does not make the repo any less
        created, so this warns and prints where to look. The warning still
        lands in the end-of-run tally.
    .PARAMETER Handle
        What Start-TemplateSync returned. $null means there is nothing to wait
        for, and it has already said why.
    .PARAMETER TimeoutSeconds
        How long to wait, covering both the wait for the run to appear and the
        wait for it to end. A clean sync stops after its own fetch-and-compare
        and is well under a minute, but this also has to absorb the runner
        queue and the workflow's concurrency group, which can hold a dispatch
        behind the nightly run.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OwnerRepo,
        [AllowNull()][hashtable]$Handle,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 300,
        [ValidateRange(1, 3600)][int]$PollSeconds = 5
    )

    if (-not $Handle) { return }

    Write-Doing 'Waiting for Template Sync'
    $run = Wait-TemplateSyncRun -OwnerRepo $OwnerRepo -PriorRunId $Handle.PriorRunId `
        -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
    if (-not $run) { return }

    Test-TemplateSyncClean -OwnerRepo $OwnerRepo -RunUrl $run.Url
}

Export-ModuleMember -Function @(
    'Get-WorkflowRunId'
    'Wait-WorkflowRunStart'
    'Wait-WorkflowRunFinish'
    'Start-TemplateSync'
    'Wait-TemplateSync'
)
