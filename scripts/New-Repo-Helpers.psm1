#Requires -Version 7.0
<#
    Shared helpers for creating a new repo derived from a template repo.
    See scripts/README.md for the design.

    Inherited by merge, so keep it identical at every layer:
    a per-layer edit conflicts on every future template change.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

# No -Force here. Import-Module -Force removes the module first, which would
# also tear it out of the calling script's scope - so the entry script owns
# -Force and a nested import is a no-op once it is already loaded.
Import-Module (Join-Path $PSScriptRoot 'Common-Console.psm1')
Import-Module (Join-Path $PSScriptRoot 'Common-Input.psm1')
Import-Module (Join-Path $PSScriptRoot 'Common-Process.psm1')

#───────────────────────────────────────────────────────────────────────────────
# Configuration
#───────────────────────────────────────────────────────────────────────────────

$script:RepoOwner = 'TaffarelJr'
$script:TemplateBranch = 'main'

# Files that exist ONLY in the base .github repo.
# Single source of truth: the same table drives both the deletion
# and the README de-linking, so the two can't drift apart.
# 'Label' is the markdown link-reference label the README uses for it.
$script:TemplateOnlyFiles = @(
    @{ Path = '.github/FUNDING.yml'; Label = 'fundingFile' }
    @{ Path = '.github/ISSUE_TEMPLATE/config.yml'; Label = 'issueChooserFile' }
)

function Get-RepoOwner {
    <#
    .SYNOPSIS
        Returns the GitHub account that owns every template layer,
        and everything derived from one.
    #>
    return $script:RepoOwner
}

function Get-TemplateBranch {
    <#
    .SYNOPSIS
        Returns the branch every template is tracked on. Always 'main'.
    #>
    return $script:TemplateBranch
}

#───────────────────────────────────────────────────────────────────────────────
# Console output
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
    Write-Host "  ⚠️  $Msg" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Msg)
    Write-Host "  ❌ $Msg" -ForegroundColor Red
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

# Aligned label/value pair, for the run header in step 0.
function Write-Field {
    # An empty -Label is allowed:
    # it renders a continuation line under the field above.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [string]$Value
    )

    Write-Host ("  ·  {0,-18}{1}" -f $Label, $Value) -ForegroundColor Gray
}

function Write-Step {
    <#
    .SYNOPSIS
        Starts a step, recording it so a failure banner can name what went wrong.
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
        Scaffolding is resumable, so it also says what to do next.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)
    Write-Host ""
    Write-Host $script:Rule -ForegroundColor Red
    $where = if ($script:CurrentStep -ne '') {
        " — STEP $($script:CurrentStep) · $($script:CurrentStepTitle)"
    }
    else { '' }
    Write-Host " ❌ SCAFFOLDING FAILED$where" -ForegroundColor Red
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
    Write-Host ""
    Write-Host '  Nothing rolled back. Re-run to resume where it left off.' `
        -ForegroundColor Yellow
    Write-Host ""
}

#───────────────────────────────────────────────────────────────────────────────
# Run state
#───────────────────────────────────────────────────────────────────────────────

# Not a tally: did this run change anything?
# Gates the Template Sync dispatch and the "already fully scaffolded"
# message, so a successful no-op must not count.
$script:ChangeCount = 0


# Flags that this run changed real state; see $script:ChangeCount.
function Add-Change {
    $script:ChangeCount++
}

# Reports whether this run changed anything; see Add-Change.
function Get-ChangeCount { return $script:ChangeCount }

#───────────────────────────────────────────────────────────────────────────────
# Manual follow-up checklist (things with no API)
#───────────────────────────────────────────────────────────────────────────────

$script:ManualItems = [System.Collections.Generic.List[object]]::new()

function Add-ManualItem {
    <#
    .SYNOPSIS
        Adds one entry to the end-of-run manual checklist.
    #>
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Steps = @()
    )
    $script:ManualItems.Add([pscustomobject]@{
            Category = $Category
            Title    = $Title
            Steps    = $Steps
        })
}

function Register-ManualSetting {
    <#
    .SYNOPSIS
        Queues the repo settings GitHub only exposes in the web UI (no REST API).
    #>
    param(
        [Parameter(Mandatory)][string]$OwnerRepo,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )
    # NB: release immutability is NOT listed here - it has a real API now,
    # handled by Enable-ReleaseImmutability, which re-adds it to this
    # list only if the call fails.
    $cat = 'GitHub settings — web UI only (no API)'
    $url = "https://github.com/$OwnerRepo/settings"

    $steps = @(
        "$url  →  General"
        "check 'Limit how many branches and tags can be updated"
        "in a single push'  →  set 2"
    )
    Add-ManualItem -Category $cat `
        -Title 'Limit branches/tags updated per push to 2' `
        -Steps $steps

    $steps = @(
        "$url  →  Moderation options  →  Code review limits"
        "check 'Limit to users explicitly granted read or higher access'"
    )
    Add-ManualItem -Category $cat `
        -Title 'Restrict code review to users with read+ access' `
        -Steps $steps

    $steps = @(
        "$url/security_analysis  →  enable 'Grouped security updates'"
    )
    Add-ManualItem -Category $cat `
        -Title 'Enable grouped security updates' `
        -Steps $steps

    # A public repo always has the dependency graph on, with no toggle,
    # so only a private one needs asking about.
    if ($Visibility -eq 'Private') {
        $steps = @("$url/security_analysis  →  enable 'Dependency graph'")
        Add-ManualItem -Category $cat `
            -Title 'Enable the Dependency graph' `
            -Steps $steps
    }

    $steps = @(
        "https://github.com/$OwnerRepo"
        'the Settings app applies settings.yml within a few minutes'
    )
    Add-ManualItem -Category $cat `
        -Title 'Verify the description and topics appear on the home page' `
        -Steps $steps
}

function Show-ManualChecklist {
    <#
    .SYNOPSIS
        Prints everything Add-ManualItem queued, grouped by category.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    if ($script:ManualItems.Count -eq 0) {
        Write-Host "`n✅ No manual follow-up needed." -ForegroundColor Green
        return
    }
    $rule = '─' * 72
    Write-Host ""
    Write-Host $rule -ForegroundColor Yellow
    Write-Host " 📋 MANUAL FOLLOW-UP — $OwnerRepo" -ForegroundColor Yellow
    Write-Host "    Not automatable; do them in the web UI when convenient." `
        -ForegroundColor Yellow
    Write-Host $rule -ForegroundColor Yellow
    foreach ($group in ($script:ManualItems | Group-Object Category)) {
        Write-Host ""
        Write-Host "  ▸ $($group.Name)" -ForegroundColor Cyan
        $n = 1
        foreach ($item in $group.Group) {
            Write-Host ("    {0}. [ ] {1}" -f $n, $item.Title) `
                -ForegroundColor White
            foreach ($s in $item.Steps) {
                Write-Host "           $s" -ForegroundColor DarkGray
            }
            $n++
        }
    }
    Write-Host ""
}

#───────────────────────────────────────────────────────────────────────────────
# Layer modules
#───────────────────────────────────────────────────────────────────────────────

# A layer module is named New-Repo-<NN>-<slug>.psm1. The tier number is what
# makes it a layer rather than just a module: this folder also holds shared
# modules and other scripts' modules, and loading one of those as a layer
# would be wrong. Requiring the digits keeps the two apart by name alone.
$script:LayerModulePattern = '^New-Repo-\d+-.+\.psm1$'

function Get-LayerModule {
    <#
    .SYNOPSIS
        Finds every layer module alongside this one, in load order.
    .DESCRIPTION
        A layer adds one by dropping it in - nothing inherited gets edited.

        Sorted by filename, which is why the convention carries the tier
        number. Import order is not what matters (every module is -Global,
        and calls happen later); the tier fixes the order their entry points
        RUN in, so a parent's scaffolding finishes before a child's starts.

        The extension is checked explicitly
        because a Windows -Filter of '*.psm1' matches loosely.
    #>
    $files = Get-ChildItem -Path $PSScriptRoot `
        -Filter '*.psm1' `
        -File `
        -ErrorAction SilentlyContinue
    $files = $files | Where-Object {
        $_.Extension -eq '.psm1' -and $_.Name -match $script:LayerModulePattern
    }
    return @($files | Sort-Object Name)
}

function Import-LayerModule {
    <#
    .SYNOPSIS
        Loads every layer module and returns those that contribute an entry point.
    .DESCRIPTION
        Imported -Global, so each layer's exported helpers are visible
        to the layers below it.

        An entry point is found from the module's own ExportedFunctions by the
        Invoke-*Scaffold pattern, so it is never coupled to the filename.
        A module may export none - a layer is free to contribute helpers only -
        but two or more is ambiguous and throws.
    #>
    $pattern = 'Invoke-*Scaffold'
    $loaded = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-LayerModule) {
        $mod = Import-Module $file.FullName -Force -Global -PassThru

        $entry = @($mod.ExportedFunctions.Values |
            Where-Object { $_.Name -like $pattern })

        if ($entry.Count -gt 1) {
            throw ("$($file.Name) exports $($entry.Count) $pattern " +
                "entry points, so the order is ambiguous: " +
                "$($entry.Name -join ', ').")
        }
        if ($entry.Count -eq 0) {
            Write-Info "$($file.Name) - helpers only, no entry point"
            continue
        }

        $loaded.Add([pscustomobject]@{
                Name   = $file.Name
                Module = $mod
                Entry  = $entry[0]
            })
    }

    return $loaded.ToArray()
}

function Remove-LayerModule {
    <#
    .SYNOPSIS
        Unloads the layer modules so an interactive session isn't left holding them.
    #>
    foreach ($file in Get-LayerModule) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        Remove-Module $name -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LayerModule {
    <#
    .SYNOPSIS
        Runs each layer module's entry point, base layer first.
        No-op if the chain has none.
    .DESCRIPTION
        Layers commit their own work via Invoke-GatedCommit.
        This only warns if one leaves changes uncommitted,
        since every later step stages an explicit pathspec.
    .PARAMETER Context
        RepoPath, RepoName, Kind, OwnerRepo, SourceOwnerRepo.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $layers = Import-LayerModule
    if (-not $layers) {
        Write-Skip ('No Helpers-*.psm1 layers in this chain - ' +
            'nothing template-specific to apply')
        return
    }
    # Snapshot first, so the check below reports only what the LAYERS dirtied.
    # The developer's own uncommitted work was already there,
    # and is none of our business.
    $status = {
        @(git -C $RepoPath status --porcelain 2>$null)
        $global:LASTEXITCODE = 0
    }
    $before = @(& $status)

    foreach ($layer in $layers) {
        Write-Info "$($layer.Name) -> $($layer.Entry.Name)"
        & $layer.Entry -Context $Context
    }

    # A layer that changed files but committed nothing
    # would leave them uncommitted forever:
    # every later step stages an explicit pathspec,
    # so nothing else picks them up.
    $left = @((& $status) | Where-Object { $_ -notin $before })
    if ($left) {
        Write-Warn "$($left.Count) file(s) changed by a layer, uncommitted"
        foreach ($l in $left) { Write-Detail $l.Trim() }
        Write-Detail 'a layer should commit via Invoke-GatedCommit'
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Context & prerequisites
#───────────────────────────────────────────────────────────────────────────────

function Get-TemplateContext {
    <#
    .SYNOPSIS
        Discovers the SOURCE template repo from the calling script's location.
    .DESCRIPTION
        The scripts live in <templateRepo>/scripts,
        so the repo root is the parent of $ScriptRoot,
        and new repos are cloned next to it (ParentDir).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptRoot)

    $sourceRoot = Split-Path -Parent $ScriptRoot
    if (-not (Test-Path (Join-Path $sourceRoot '.git'))) {
        throw ("No git repo at '$sourceRoot'. " +
            "Run this from a template repo's scripts/ folder.")
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git not found on PATH."
    }
    if (-not (Get-Command gh  -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found on PATH."
    }

    $originUrl = (git -C $sourceRoot remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $originUrl) {
        throw "Could not read 'origin' remote from '$sourceRoot'."
    }
    $originUrl = $originUrl.Trim()

    if ($originUrl -notmatch '[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') {
        throw "Could not parse owner/repo from origin URL '$originUrl'."
    }
    if ($Matches['owner'] -ne $script:RepoOwner) {
        Write-Warn ("This repo's origin owner is '$($Matches['owner'])' " +
            "but the configured owner is '$($script:RepoOwner)'. " +
            "Update `$script:RepoOwner in New-Repo-Helpers.psm1 if that's wrong.")
    }
    [pscustomobject]@{
        SourceOwner     = $Matches['owner']
        SourceRepo      = $Matches['repo']
        SourceOwnerRepo = "$($Matches['owner'])/$($Matches['repo'])"
        SourceRoot      = $sourceRoot
        # SourceUrl is reused verbatim as the new repo's 'template' remote.
        SourceUrl       = $originUrl
        ParentDir       = Split-Path -Parent $sourceRoot
    }
}

function Get-TemplateChain {
    <#
    .SYNOPSIS
        Walks the inheritance chain upward from $StartRepoPath,
        following each repo's 'template' remote.
    .DESCRIPTION
        Returns the LOCAL paths of every layer, nearest first:
            [ .template-nuget, .template-dotnet, .github ]

        Each ancestor is located by repo name,
        as a sibling folder in $ParentDir.
        Walking stops when a repo has no 'template' remote (the base),
        or when the next ancestor isn't cloned locally.
        Cycles and runaway depth are guarded.
    #>
    param(
        [Parameter(Mandatory)][string]$StartRepoPath,
        [Parameter(Mandatory)][string]$ParentDir,
        [int]$MaxDepth = 10
    )
    $chain = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()

    $cur = (Resolve-Path $StartRepoPath).Path
    [void]$seen.Add($cur.ToLowerInvariant())
    $chain.Add($cur)

    for ($i = 0; $i -lt $MaxDepth; $i++) {
        $url = git -C $cur remote get-url template 2>$null
        # A missing 'template' remote means the base layer was reached.
        if ($LASTEXITCODE -ne 0 -or -not $url) { break }
        if ($url.Trim() -notmatch '[:/][^/]+/([^/]+?)(\.git)?$') { break }
        $ancestorPath = Join-Path $ParentDir $Matches[1]
        if (-not (Test-Path (Join-Path $ancestorPath '.git'))) {
            Write-Info ("Ancestor '$($Matches[1])' isn't cloned locally - " +
                'ending chain walk')
            break
        }
        $resolved = (Resolve-Path $ancestorPath).Path
        if (-not $seen.Add($resolved.ToLowerInvariant())) { break }    # cycle
        $chain.Add($resolved)
        $cur = $resolved
    }
    # Reaching the base layer means the last `git remote get-url template`
    # failed by design. Clear the leaked exit code so a later Assert-LastExit
    # doesn't see a phantom failure.
    $global:LASTEXITCODE = 0
    return $chain.ToArray()
}

#───────────────────────────────────────────────────────────────────────────────
# gh authentication (borrowed for this run only)
#───────────────────────────────────────────────────────────────────────────────

# Pushed by Use-GhAccount, popped by Reset-GhAccount.
$script:GhStatePushed = $false
$script:PriorGhToken = $null
$script:PriorGhAccount = $null

function Get-ActiveGhAccount {
    <#
    .SYNOPSIS
        Returns the login gh is authenticating as, or $null if the call failed.
    .DESCRIPTION
        gh writes error bodies to STDOUT,
        so a failed call returns JSON rather than nothing -
        which would otherwise be captured and later fed to
        `gh auth switch --user`.
        Guard on the exit code, then reject anything with JSON punctuation.
        Deny-listing rather than allow-listing,
        because logins legitimately contain characters like the underscore
        in enterprise-managed accounts.
    #>
    $login = gh api user --jq .login 2>$null
    $ok = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0
    if (-not $ok -or -not $login) { return $null }
    $login = ($login | Out-String).Trim()
    if (-not $login -or $login -match '[\s{}\[\]":,]') { return $null }
    return $login
}

function Use-GhAccount {
    <#
    .SYNOPSIS
        Points this process's gh calls at the repo owner,
        then verifies it has admin access.
    .DESCRIPTION
        Borrows the owner's token into $env:GH_TOKEN,
        rather than running `gh auth switch`,
        which would repoint every other shell on the machine.
        Records any prior GH_TOKEN and active account first,
        so Reset-GhAccount can put both back exactly as they were.
    #>
    param([Parameter(Mandatory)][string]$ProbeOwnerRepo)

    $account = $script:RepoOwner

    # Push the state we are about to change,
    # so the pop can be exact rather than approximate.
    $script:PriorGhToken = $env:GH_TOKEN
    $script:PriorGhAccount = Get-ActiveGhAccount
    $script:GhStatePushed = $true

    $token = gh auth token --user $account 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        $global:LASTEXITCODE = 0
        if (Test-SkipPrompt) {
            throw ("No stored credentials for gh account '$account', " +
                'and prompts are suppressed. ' +
                'Run: gh auth login   (then re-run unattended.)')
        }
        Write-Warn ("No stored credentials for gh account '$account' - " +
            "starting 'gh auth login'")
        Write-Detail "sign in as '$account'; your other accounts stay logged in"
        gh auth login --hostname github.com
        if ($LASTEXITCODE -ne 0) {
            $global:LASTEXITCODE = 0
            throw "'gh auth login' did not complete."
        }
        $global:LASTEXITCODE = 0

        $token = gh auth token --user $account 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $token) {
            $global:LASTEXITCODE = 0
            throw ("Still no credentials for '$account' - " +
                'did you sign in as a different account?')
        }
        $global:LASTEXITCODE = 0
    }
    $env:GH_TOKEN = $token.Trim()
    Write-Ok "Using gh account '$account' for this run only"

    $active = Get-ActiveGhAccount
    if (-not $active) {
        throw "Not authenticated with gh. Run 'gh auth login' first."
    }

    # Admin probe:
    # being logged in is not the same as having the scopes we need.
    $probe = "repos/$ProbeOwnerRepo/actions/permissions/workflow"
    gh api $probe --silent 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0
    if (-not $ok) {
        throw ("Account '$active' lacks admin access to " +
            "'$ProbeOwnerRepo'. If it is a scope issue, run: gh auth refresh " +
            '-h github.com -s admin:repo_hook,workflow,security_events')
    }
    Write-Ok "Admin access confirmed (gh account: $active)"
}

function Reset-GhAccount {
    <#
    .SYNOPSIS
        Restores the gh token and active account recorded by Use-GhAccount.
    .DESCRIPTION
        Puts back a GH_TOKEN that was already set,
        rather than just clearing ours,
        and switches the active account back if `gh auth login` changed it.
        Safe to call more than once,
        and a no-op if nothing was ever pushed,
        so it can run on both the success and failure paths.
    #>
    if (-not $script:GhStatePushed) { return }

    if ($script:PriorGhToken) { $env:GH_TOKEN = $script:PriorGhToken }
    elseif ($env:GH_TOKEN) {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    }

    # `gh auth login` makes the account it signed in as active;
    # put the previous one back.
    if ($script:PriorGhAccount) {
        $active = Get-ActiveGhAccount
        if ($active -and $active -ne $script:PriorGhAccount) {
            gh auth switch --user $script:PriorGhAccount 2>$null | Out-Null
            $global:LASTEXITCODE = 0
            Write-Info ("Restored '$($script:PriorGhAccount)' " +
                'as the active gh account')
        }
    }

    $script:GhStatePushed = $false
    Write-Info 'Released the borrowed gh token'
}

#───────────────────────────────────────────────────────────────────────────────
# Step: create the repo (idempotent)
#───────────────────────────────────────────────────────────────────────────────

function New-GitHubRepo {
    <#
    .SYNOPSIS
        Creates an empty repo. No-op if it already exists.
    .DESCRIPTION
        An existing repo keeps whatever visibility it already has: changing
        that is not something a scaffolding re-run should do behind your back.
        settings.yml is where visibility is declared from then on.
    #>
    param(
        [Parameter(Mandatory)][string]$OwnerRepo,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )
    $actual = gh repo view $OwnerRepo --json visibility --jq '.visibility' `
        2>$null
    if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        $actual = ($actual | Out-String).Trim().ToLowerInvariant()
        Write-Skip "Repo $OwnerRepo already exists ($actual)"
        if ($actual -and $actual -ne $Visibility.ToLowerInvariant()) {
            Write-Warn ("Existing repo is $actual, but -Visibility says " +
                "$Visibility - left as-is")
        }
        return
    }
    $global:LASTEXITCODE = 0

    $flag = "--$($Visibility.ToLowerInvariant())"
    Invoke-Gh -What "Creating $OwnerRepo" `
        -Arguments @('repo', 'create', $OwnerRepo, $flag) | Out-Null
    Add-Change
    Write-Ok "Created empty $($Visibility.ToLowerInvariant()) repo $OwnerRepo"
}

#───────────────────────────────────────────────────────────────────────────────
# Step: repo settings (API-settable, all idempotent)
#───────────────────────────────────────────────────────────────────────────────

function Set-WorkflowPermission {
    <#
    .SYNOPSIS
        Allows GitHub Actions to create and approve PRs,
        preserving the default permissions.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    # gh writes its error body to STDOUT,
    # so a failed GET still parses - into an object with message/status.
    # Under StrictMode, reading a missing property throws, so test first.
    $endpoint = "repos/$OwnerRepo/actions/permissions/workflow"
    $json = gh api $endpoint 2>$null
    $cur = $json | ConvertFrom-Json
    $global:LASTEXITCODE = 0
    $props = if ($cur) { @($cur.PSObject.Properties.Name) } else { @() }

    if ($props -contains 'can_approve_pull_request_reviews' -and
        $cur.can_approve_pull_request_reviews) {
        Write-Skip 'Actions create/approve PRs already enabled'; return
    }
    $perm = if ($props -contains 'default_workflow_permissions') {
        $cur.default_workflow_permissions
    }
    else { 'read' }
    $ghArgs = @(
        'api', '--method', 'PUT', $endpoint
        '-f', "default_workflow_permissions=$perm"
        '-F', 'can_approve_pull_request_reviews=true'
    )
    Invoke-Gh -What 'Allowing Actions to create and approve PRs' `
        -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Ok "Actions: allowed to create and approve pull requests"
}

function Enable-PrivateVulnReporting {
    <#
    .SYNOPSIS
        Enables private vulnerability reporting. No-op if already on.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)
    $endpoint = "repos/$OwnerRepo/private-vulnerability-reporting"
    $enabled = gh api $endpoint --jq '.enabled' 2>$null
    if ($LASTEXITCODE -eq 0 -and $enabled -eq 'true') {
        Write-Skip 'Private vulnerability reporting already enabled'
        return
    }
    # Tolerated rather than asserted: GitHub 422s when the repo is not
    # eligible, and losing one setting should not fail an otherwise good run.
    gh api --method PUT $endpoint --silent 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    $global:LASTEXITCODE = 0
    if ($ok) {
        Add-Change
        Write-Ok 'Enabled private vulnerability reporting'
        return
    }

    Write-Warn ('Could not enable private vulnerability reporting - ' +
        'added to the checklist')
    $steps = @(
        "https://github.com/$OwnerRepo/settings/security_analysis"
        "enable 'Private vulnerability reporting'"
    )
    Add-ManualItem -Category 'GitHub settings — web UI only (no API)' `
        -Title 'Enable private vulnerability reporting' `
        -Steps $steps
}

function Set-RepoSecret {
    <#
    .SYNOPSIS
        Adds a repo secret, without ever overwriting an existing one.
    .DESCRIPTION
        A personal account cannot share an Actions secret across repos - that
        is an organization feature - so every secret is per-repo and this runs
        once per new repo.

        Never overwrites: a secret that is already there was more likely set
        deliberately than left over by mistake, and silently replacing a
        working token is worse than leaving it alone.
    .PARAMETER Name
        The secret's name, e.g. CODECOV_TOKEN.
    .PARAMETER Token
        The value. Empty warns and returns, because a missing token is a thing
        to go and do rather than a reason to fail the run.
    #>
    param(
        [Parameter(Mandatory)][string]$OwnerRepo,
        [Parameter(Mandatory)][string]$Name,
        [string]$Token
    )
    $secrets = gh secret list --repo $OwnerRepo 2>$null
    # Listing may legitimately fail; don't leak that to a later Assert-LastExit.
    $global:LASTEXITCODE = 0
    $exists = @($secrets) -match "^$Name\b"
    if ($exists) {
        Write-Skip "$Name already set (change it with 'gh secret set')"
        return
    }
    if (-not $Token) {
        Write-Warn "$Name not provided - add it with gh secret set"
        return
    }
    $ghArgs = @(
        'secret', 'set', $Name
        '--repo', $OwnerRepo
        '--body', $Token
    )
    Invoke-Gh -What "Setting the $Name secret" -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Ok "Added repo secret $Name"
}

function Set-RepoVariable {
    <#
    .SYNOPSIS
        Adds a repo variable, without ever overwriting an existing one.
    .DESCRIPTION
        A variable rather than a secret, because these are switches and paths
        - things worth being able to read back. Same no-overwrite rule as
        Set-RepoSecret.
    #>
    param(
        [Parameter(Mandatory)][string]$OwnerRepo,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    $variables = gh variable list --repo $OwnerRepo 2>$null
    $global:LASTEXITCODE = 0
    $exists = @($variables) -match "^$Name\b"
    if ($exists) {
        Write-Skip "$Name already set (change it with 'gh variable set')"
        return
    }
    $ghArgs = @(
        'variable', 'set', $Name
        '--repo', $OwnerRepo
        '--body', $Value
    )
    Invoke-Gh -What "Setting the $Name variable" -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Ok "Added repo variable $Name = $Value"
}

function Initialize-Topic {
    <#
    .SYNOPSIS
        Seeds one throwaway topic, so settings.yml can manage topics after that.
    .DESCRIPTION
        The Settings app's topics call does not land on a repo
        that has never had a topic.
        The real list stays in settings.yml,
        which overwrites this seed on the next sync.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    $current = gh api "repos/$OwnerRepo/topics" --jq '.names | length' 2>$null
    $global:LASTEXITCODE = 0
    if ($current -and [int]$current -gt 0) {
        Write-Skip "Topics already seeded ($current) - settings.yml owns them"
        return
    }

    $ghArgs = @(
        'api', '--method', 'PUT', "repos/$OwnerRepo/topics"
        '-f', 'names[]=github'
    )
    Invoke-Gh -What 'Seeding a placeholder topic' `
        -Arguments $ghArgs | Out-Null
    Add-Change
    Write-Ok "Seeded topic 'github'"
    Write-Detail 'settings.yml replaces this on the next sync'
}

function Enable-ReleaseImmutability {
    <#
    .SYNOPSIS
        Enables immutable releases, locking assets and tags once published.
    .DESCRIPTION
        Uses the dedicated /immutable-releases endpoints;
        the repo PATCH endpoint has no field for it.
        Still in preview, so a failure falls back to the manual checklist.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    # GET returns 204 when enabled and 404 when not,
    # so the exit code is the answer.
    $endpoint = "repos/$OwnerRepo/immutable-releases"
    gh api $endpoint --silent 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        Write-Skip 'Immutable releases already enabled'
        return
    }
    $global:LASTEXITCODE = 0

    gh api --method PUT $endpoint --silent 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $global:LASTEXITCODE = 0
        Add-Change
        Write-Ok 'Enabled immutable releases'
        return
    }
    $global:LASTEXITCODE = 0
    Write-Warn ("Couldn't enable immutable releases via the API " +
        '(still in preview) - added to the checklist')
    $steps = @(
        "https://github.com/$OwnerRepo/settings  →  General"
        "check 'Enable release immutability'"
    )
    Add-ManualItem -Category 'GitHub settings — web UI only (no API)' `
        -Title 'Enable release immutability' `
        -Steps $steps
}

#───────────────────────────────────────────────────────────────────────────────
# Step: CodeQL default setup
#───────────────────────────────────────────────────────────────────────────────

# CodeQL languages this run should analyse. Layers add to it;
# Enable-Codeql applies the union at the end. Seeded with 'actions'
# because every repo here carries workflows, AND the inherited "Status checks
# must pass" ruleset requires the `Analyze (actions)` check - dropping it would
# leave that check permanently pending and block every PR.
$script:CodeqlLanguages = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('actions'), [System.StringComparer]::OrdinalIgnoreCase)

# The complete set GitHub accepts for code scanning default setup.
$script:CodeqlValidLanguages = @(
    'actions'                 # GitHub Actions workflows
    'c-cpp'                   # C and C++
    'csharp'                  # C#
    'go'                      # Go
    'java-kotlin'             # Java and Kotlin
    'javascript-typescript'   # JavaScript and TypeScript
    'python'                  # Python
    'ruby'                    # Ruby
    'swift'                   # Swift
)

function Add-CodeqlLanguage {
    <#
    .SYNOPSIS
        Registers CodeQL languages for this layer, adding to the inherited list.
    .PARAMETER Language
        One or more of: actions, c-cpp, csharp, go, java-kotlin,
        javascript-typescript, python, ruby, swift.
        Anything else throws.
    #>
    param([Parameter(Mandatory)][string[]]$Language)
    foreach ($lang in $Language) {
        $l = $lang.Trim()
        if ($l -notin $script:CodeqlValidLanguages) {
            throw ("'$l' is not a CodeQL language. Valid values: " +
                ($script:CodeqlValidLanguages -join ', '))
        }
        if ($script:CodeqlLanguages.Add($l)) {
            Write-Detail "CodeQL will analyse '$l'"
        }
    }
}

function Get-CodeqlLanguage {
    <#
    .SYNOPSIS
        Returns the languages registered so far, for inspection or testing.
    #>
    return @($script:CodeqlLanguages | Sort-Object)
}

function Enable-Codeql {
    <#
    .SYNOPSIS
        Enables CodeQL default setup for every language the chain registered.
    .DESCRIPTION
        Languages come from Add-CodeqlLanguage.
        Call this AFTER the first push - the repo needs content.

        Unlike the other settings helpers,
        this does NOT simply skip when already configured:
        a layer may have added a language since,
        so it extends the existing list instead.
        What is already configured is always kept,
        so a language enabled by hand is never removed.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    $endpoint = "repos/$OwnerRepo/code-scanning/default-setup"
    $existing = @(gh api $endpoint --jq '.languages[]?' 2>$null)
    $state = gh api $endpoint --jq '.state' 2>$null
    $global:LASTEXITCODE = 0

    $wanted = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$existing, [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($l in $script:CodeqlLanguages) { [void]$wanted.Add($l) }
    $langs = @($wanted | Sort-Object)

    $added = @($langs | Where-Object { $_ -notin $existing })
    if ($state -eq 'configured' -and -not $added) {
        Write-Skip "CodeQL already analysing: $($langs -join ', ')"
        return
    }

    # PATCH, not PUT: GitHub does not route PUT here and answers with a bare,
    # generic 404.
    $ghArgs = @('api', '--method', 'PATCH', $endpoint,
        '-f', 'state=configured')
    foreach ($l in $langs) { $ghArgs += @('-f', "languages[]=$l") }
    & gh @ghArgs --silent 2>$null | Out-Null
    $enabled = ($LASTEXITCODE -eq 0)
    # This failure is tolerated; don't leak it to a later Assert-LastExit.
    $global:LASTEXITCODE = 0

    if (-not $enabled) {
        # GitHub 422s on a language the repo does not contain -
        # expected for a template that declares csharp before it has any C#.
        # Fall back to whatever is actually there.
        $retry = @(
            'api', '--method', 'PATCH', $endpoint
            '-f', 'state=configured'
        )
        & gh @retry --silent 2>$null | Out-Null
        $enabled = ($LASTEXITCODE -eq 0)
        $global:LASTEXITCODE = 0
        if ($enabled) {
            $now = @(gh api $endpoint --jq '.languages[]?' 2>$null)
            $global:LASTEXITCODE = 0
            $missing = @($langs | Where-Object { $_ -notin $now })
            $nowList = ($now | Sort-Object) -join ', '
            $fresh = @($now | Where-Object { $_ -notin $existing })
            $changed = $fresh -or -not $existing
            if ($changed) {
                Add-Change
                Write-Ok "CodeQL default setup enabled: $nowList"
            }
            else {
                # Nothing moved, so report a skip -
                # this keeps the change count at zero
                # for an already-scaffolded repo.
                Write-Skip "CodeQL already analysing: $nowList"
            }
            if ($missing) {
                Write-Detail ('not in the repo yet, so not enabled: ' +
                    ($missing -join ', '))
                Write-Detail 're-run once that code exists to add them'
            }
            return
        }
    }

    if ($enabled) {
        Add-Change
        Write-Ok "CodeQL default setup enabled: $($langs -join ', ')"
    }
    else {
        # Code scanning may be unavailable on the repo entirely.
        # Hand it to the checklist rather than failing;
        # a later re-run will pick it up.
        Write-Warn ('CodeQL default setup not enabled automatically - ' +
            'added to the checklist')
        $steps = @(
            "https://github.com/$OwnerRepo/settings/security_analysis"
            'Code scanning  →  Default  →  Enable'
            'Or just re-run this script once the repo is a few minutes old.'
        )
        Add-ManualItem -Category 'GitHub settings — web UI only (no API)' `
            -Title 'Set up CodeQL default analysis' `
            -Steps $steps
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Step: clone & wire up remotes (resume-safe)
#───────────────────────────────────────────────────────────────────────────────

function Get-NewRepoUrl {
    <#
    .SYNOPSIS
        Builds the git URL for a sibling repo,
        by swapping the owner/repo path in the source URL.
    .DESCRIPTION
        Preserves the host and protocol,
        including a custom SSH alias like git@github.com-personal:...,
        so the new repo's origin uses the same credentials.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$RepoName
    )
    $old = "$($Context.SourceOwner)/$($Context.SourceRepo)"
    $new = "$($Context.SourceOwner)/$RepoName"
    $url = $Context.SourceUrl -replace [regex]::Escape($old), $new
    if ($url -eq $Context.SourceUrl) {
        throw "Could not derive sibling URL from '$($Context.SourceUrl)'."
    }
    return $url
}

function Initialize-LocalRepo {
    <#
    .SYNOPSIS
        Ensures the 'template' remote, the push default, the commit template,
        and that 'main' exists and is checked out.
    .DESCRIPTION
        Idempotent. Creates main from the template branch
        ONLY if it doesn't already exist,
        so resuming never resets existing history.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$TemplateUrl
    )
    git -C $RepoPath config remote.pushdefault origin | Out-Null
    $remotes = git -C $RepoPath remote 2>$null
    if ($remotes -notcontains 'template') {
        Invoke-Git -What "Adding the 'template' remote" `
            -RepoPath $RepoPath `
            -Arguments @('remote', 'add', 'template', $TemplateUrl) | Out-Null
    }
    else {
        git -C $RepoPath remote set-url template $TemplateUrl | Out-Null
    }
    Invoke-Git -What 'Fetching the template remote' `
        -RepoPath $RepoPath -Arguments @('fetch', 'template') | Out-Null
    git -C $RepoPath config commit.template .gitmessage | Out-Null

    git -C $RepoPath show-ref --verify --quiet refs/heads/main
    if ($LASTEXITCODE -ne 0) {
        $templateRef = "template/$($script:TemplateBranch)"
        Invoke-Git -What "Creating main from $templateRef" `
            -RepoPath $RepoPath `
            -Arguments @('checkout', '-B', 'main', $templateRef) | Out-Null
    }
    else {
        $branch = git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
        if ($branch -ne 'main') {
            Invoke-Git -What 'Switching to main' -RepoPath $RepoPath `
                -Arguments @('checkout', 'main') | Out-Null
        }
    }
}

function Initialize-Clone {
    <#
    .SYNOPSIS
        Clones the new repo next to the template,
        or reuses an existing local clone.
    #>
    param(
        [Parameter(Mandatory)][string]$OriginUrl,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$TemplateUrl
    )
    if (Test-Path $TargetPath) {
        if (-not (Test-Path (Join-Path $TargetPath '.git'))) {
            throw ("Path exists but is not a git repo: $TargetPath " +
                '(remove it and retry).')
        }
        Write-Skip "Local clone already present - reusing without reset"
    }
    else {
        # git clone (not `gh repo clone`) keeps the URL's host alias/creds.
        Invoke-Git -What "Cloning $OriginUrl" `
            -Arguments @('clone', $OriginUrl, $TargetPath) | Out-Null
        Add-Change
        Write-Ok "Cloned $OriginUrl"
        Write-Detail "-> $TargetPath"
    }
    Initialize-LocalRepo -RepoPath $TargetPath -TemplateUrl $TemplateUrl
    Write-Ok "'template' remote -> $TemplateUrl; on branch main"
}

#───────────────────────────────────────────────────────────────────────────────
# Step: customize files (each edit is idempotent on its own)
#───────────────────────────────────────────────────────────────────────────────

function Remove-TemplateOnlyFile {
    <#
    .SYNOPSIS
        Deletes the files listed in $TemplateOnlyFiles,
        which live ONLY in the base .github repo.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $gone = 0
    foreach ($entry in $script:TemplateOnlyFiles) {
        $f = Join-Path $RepoPath $entry.Path
        if (Test-Path $f) {
            Remove-Item $f
            Write-Ok "Deleted $($entry.Path)"
            $gone++
        }
    }
    if ($gone -eq 0) { Write-Skip 'No template-only files left to delete' }
}

function Update-RepoReference {
    <#
    .SYNOPSIS
        Replaces references to the source template's owner/repo with the new one's.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$OldOwnerRepo,
        [Parameter(Mandatory)][string]$NewOwnerRepo
    )
    $targets = [System.Collections.Generic.List[string]]::new()
    $targets.AddRange(
        [string[]]@('CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md'))
    $issueDir = Join-Path $RepoPath '.github/ISSUE_TEMPLATE'
    if (Test-Path $issueDir) {
        $forms = Get-ChildItem $issueDir -File
        foreach ($form in $forms) {
            $targets.Add(".github/ISSUE_TEMPLATE/$($form.Name)")
        }
    }
    foreach ($rel in $targets) {
        $f = Join-Path $RepoPath $rel
        if (Test-Path $f) {
            $raw = Get-Content -Raw $f
            if ($raw.Contains($OldOwnerRepo)) {
                $updated = $raw.Replace($OldOwnerRepo, $NewOwnerRepo)
                Set-Content -Path $f -Value $updated -NoNewline
                Write-Ok "Updated references in $rel"
            }
        }
    }
}

function Update-Readme {
    <#
    .SYNOPSIS
        De-links the README rows for the template-only files,
        then prunes the orphaned link definitions.
    .DESCRIPTION
        De-links rather than deletes:
        the table's "Exists only in .github repo" column
        is what documents that the file is deliberately absent here,
        so the row must survive.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$Labels = @($script:TemplateOnlyFiles.Label)
    )
    $f = Join-Path $RepoPath 'README.md'
    if (-not (Test-Path $f)) { Write-Skip 'README.md not found'; return }

    $raw = Get-Content -Raw $f
    $original = $raw

    # 1) '[Display Name][label]' -> 'Display Name', keeping the table row.
    foreach ($label in $Labels) {
        $raw = $raw -replace "\[([^\]]+)\]\[$([regex]::Escape($label))\]", '$1'
    }

    # 2) Garbage-collect '[label]: url' definitions nothing references any more.
    $lines = [System.Collections.Generic.List[string]]@($raw -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '^\[(?<label>[^\]]+)\]:\s') { continue }
        $token = "[$($Matches['label'])]"
        $used = $false
        for ($j = 0; $j -lt $lines.Count; $j++) {
            if ($j -eq $i) { continue }
            # Other definitions aren't usages.
            if ($lines[$j] -match '^\[[^\]]+\]:\s') { continue }
            if ($lines[$j].Contains($token)) { $used = $true; break }
        }
        if (-not $used) { $lines.RemoveAt($i) }
    }
    $raw = ($lines -join "`r`n")
    if (-not $raw.EndsWith("`r`n")) { $raw += "`r`n" }

    if ($raw -eq $original) {
        Write-Skip 'README.md already has no template-only links'
        return
    }
    $raw | Set-Content -NoNewline -Encoding utf8 $f
    Write-Ok 'De-linked the template-only files in README.md'
}

function Reset-Readme {
    <#
    .SYNOPSIS
        Replaces a code repo's inherited README with an ordinary project one.
    .DESCRIPTION
        A template's README documents the template chain - the structure
        diagram and the inventory of which file lives at which layer. None of
        that means anything in a leaf repo, and an outside contributor reading
        it learns nothing about the project. So a code repo gets a normal
        README skeleton instead: what this is, how to start, and where the
        community files are.

        Skipped unless the README is still recognisably the template's, so a
        re-run never overwrites the real README you wrote afterwards.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )
    $path = Join-Path $RepoPath 'README.md'

    # Two markers, either of which only a template's README carries.
    $isTemplate = $false
    if (Test-Path $path) {
        $raw = Get-Content -Raw $path
        $isTemplate =
        $raw.Contains('Personal GitHub Repo Structure') -or
        $raw.Contains('Description of Files in This Template Repo')
    }
    if (-not $isTemplate) {
        Write-Skip 'README.md is not the template one - leaving it alone'
        return
    }

    $summary = if ($Description) { $Description } else { 'TODO: what this is.' }
    $contributing = if ($Visibility -eq 'Private') {
        'This is a private project. Please contact the owner before'
    }
    else {
        'Contributions are welcome. Please read'
    }
    $licence = if ($Visibility -eq 'Private') {
        'All rights reserved. See [LICENSE][licenseFile].'
    }
    else {
        '[MIT][licenseFile]'
    }

    $lines = @(
        "# $RepoName <!-- omit from toc -->"
        ''
        $summary
        ''
        '#### Table of Contents <!-- omit from toc -->'
        ''
        '- [Getting Started](#getting-started)'
        '- [Contributing](#contributing)'
        '- [Support](#support)'
        '- [License](#license)'
        ''
        '## Getting Started'
        ''
        '> TODO: how to install this, and how to use it.'
        ''
        '## Contributing'
        ''
        $contributing
    )
    if ($Visibility -eq 'Private') {
        $lines += 'opening an issue or a pull request.'
    }
    else {
        $lines += '[CONTRIBUTING.md][contribFile] first,'
        $lines += 'along with the [Code of Conduct][cocFile].'
    }
    $lines += @(
        ''
        '## Support'
        ''
        'Need help? See [SUPPORT.md][supportFile].'
        'To report a vulnerability, see [SECURITY.md][securityFile].'
        ''
        '## License'
        ''
        $licence
        ''
        '<!-- Source Code URIs (alphabetical by file hierarchy) -->'
        ''
        '[cocFile]: ./CODE_OF_CONDUCT.md'
        '[contribFile]: ./CONTRIBUTING.md'
        '[licenseFile]: ./LICENSE'
        '[securityFile]: ./SECURITY.md'
        '[supportFile]: ./SUPPORT.md'
    )

    $content = ($lines -join "`r`n") + "`r`n"
    Set-Content -Path $path -Value $content -NoNewline -Encoding utf8
    Add-Change
    Write-Ok 'Replaced the template README with a project one'
}

function Update-ReadmeDiagram {
    <#
    .SYNOPSIS
        Points the README's structure diagram at the template row.
    .DESCRIPTION
        The base .github repo highlights itself, next to the note explaining
        what it is. Every template derived from it highlights the right-most
        template in the second row instead, next to the note about template
        layers, so the picture reads "you are a layer" rather than "you are
        the base". Which tier is highlighted does not matter - the point is to
        convey the layering.

        Only the BASE repo's marker is ever retargeted. That makes this both
        idempotent and correct at any depth: a second-layer template inherits
        a diagram already pointing at the template row, so there is nothing
        to change, and a repo whose diagram was rewritten by hand is left
        alone.

        A code repo never gets here - Reset-Readme has already replaced the
        whole README, diagram included.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $path = Join-Path $RepoPath 'README.md'
    if (-not (Test-Path $path)) {
        Write-Skip 'README.md not found'
        return
    }

    $from = 'class github current'
    $to = 'class templateB current'

    $raw = Get-Content -Raw $path
    if (-not $raw.Contains($from)) {
        Write-Skip 'README diagram does not highlight the base repo'
        return
    }

    Set-Content -Path $path -Value $raw.Replace($from, $to) -NoNewline
    Add-Change
    Write-Ok 'Retargeted the README diagram at the template row'
}

function Set-ReadmeTitle {
    <#
    .SYNOPSIS
        Renames the README's heading to this repo.
    .DESCRIPTION
        A derived template inherits the base README, heading included, so
        without this every repo in the chain introduces itself as
        '.github Repository'. Only the first heading is touched; the rest of
        the document belongs to whoever edits it next.

        A code repo does not need this - Reset-Readme replaces the whole file,
        because a leaf should document the project rather than the chain.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RepoName
    )

    $path = Join-Path $RepoPath 'README.md'
    if (-not (Test-Path $path)) {
        Write-Skip 'README.md not found'
        return
    }

    $raw = [System.IO.File]::ReadAllText($path)

    # Anchored to the first line so a '# ' inside the document, or inside a
    # fenced block, cannot be mistaken for the title.
    $pattern = '^#\s+(\S+)\s+Repository'
    if ($raw -notmatch $pattern) {
        Write-Skip 'README has no recognizable title to rename'
        return
    }
    if ($Matches[1] -eq $RepoName) {
        Write-Skip 'README title already names this repo'
        return
    }

    $updated = [regex]::Replace($raw, $pattern, "# $RepoName Repository", 1)
    [System.IO.File]::WriteAllText($path, $updated)
    Add-Change
    Write-Ok "Retitled the README to '$RepoName'"
}

function Set-RepoLicense {
    <#
    .SYNOPSIS
        Replaces the inherited MIT license with a proprietary notice,
        for a private repo.
    .DESCRIPTION
        MIT grants everyone the right to use, copy and sell the code, which
        is the opposite of what a private repo wants. No OSI-approved licence
        can express "nobody may use this without an arrangement", because
        permitting use is what makes a licence open source - so a private repo
        gets an explicit all-rights-reserved notice instead.

        The existing copyright line is carried over verbatim, so the holder
        and year stay whatever the chain already says.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )
    if ($Visibility -ne 'Private') {
        Write-Skip 'Public repo - keeping the inherited MIT license'
        return
    }

    $path = Join-Path $RepoPath 'LICENSE'
    if (-not (Test-Path $path)) {
        Write-Warn 'LICENSE not found'
        return
    }

    $raw = Get-Content -Raw $path
    if ($raw.StartsWith('All Rights Reserved')) {
        Write-Skip 'LICENSE is already proprietary'
        return
    }

    $copyright = "Copyright (c) $((Get-Date).Year)"
    if ($raw -match 'Copyright \(c\)[^\r\n]*') { $copyright = $Matches[0] }

    $lines = @(
        'All Rights Reserved'
        ''
        $copyright
        ''
        'This software and its source code are proprietary and confidential.'
        ''
        'No permission is granted to any person to use, copy, modify, merge,'
        'publish, distribute, sublicense, or sell copies of this software, in'
        'whole or in part, by any means, without the prior written permission'
        'of the copyright holder. Unauthorized copying, distribution, or use,'
        'via any medium, is strictly prohibited.'
        ''
        'To enquire about a licence, contact the copyright holder.'
        ''
        'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,'
        'EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF'
        'MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND'
        'NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS'
        'BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN'
        'ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN'
        'CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE'
        'SOFTWARE.'
    )
    $content = ($lines -join "`r`n") + "`r`n"
    Set-Content -Path $path -Value $content -NoNewline -Encoding utf8
    Write-Ok 'Replaced the MIT license with an all-rights-reserved notice'
    Write-Detail 'GitHub shows no licence badge for a proprietary repo'
}

function Set-TemplateSyncConfig {
    <#
    .SYNOPSIS
        Points Template Sync at this repo's parent and enables the schedule.
    .DESCRIPTION
        Retargeting matters: TEMPLATE_REPO_URL is inherited verbatim,
        so without this a level-2 repo keeps syncing from its GRANDparent,
        and never sees its actual parent's changes.
    .PARAMETER TemplateOwnerRepo
        The parent template as owner/repo,
        normalised to the https URL the workflow needs.
    .PARAMETER Strategy
        How the sync branch takes the parent's commits.
        'rebase' replays them onto this repo's main and keeps history linear,
        which is what a template layer needs
        so its own merge commits never reach a leaf.
        'merge' records a merge commit, which only a leaf does.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$TemplateOwnerRepo,
        [Parameter(Mandatory)][ValidateSet('rebase', 'merge')][string]$Strategy
    )
    $f = Join-Path $RepoPath '.github/workflows/template-sync.yml'
    if (-not (Test-Path $f)) {
        Write-Warn 'template-sync.yml not found'
        return
    }

    $raw = Get-Content -Raw $f
    $original = $raw

    # Use [^\r\n] and [ \t], never '.' or \s:
    # '.' matches CR and would convert CRLF to LF.
    $httpsUrl = "https://github.com/$TemplateOwnerRepo.git"
    $urlPattern = '(?m)^([ \t]*TEMPLATE_REPO_URL:[ \t]*)[^\r\n]*'
    $raw = $raw -replace $urlPattern, "`${1}$httpsUrl"

    # Match the SHAPE of the lines, never a specific cron:
    # half-uncommenting the block yields a 'schedule:' with no entries,
    # which GitHub rejects.
    # No '$' anchor - CRLF defeats it.
    $raw = $raw -replace '(?m)^([ \t]*)#[ \t]*(schedule:)', '$1$2'
    $raw = $raw -replace '(?m)^([ \t]*)#[ \t]*(- cron:[^\r\n]*)', '$1  $2'

    $strategyPattern = '(?m)^([ \t]*SYNC_STRATEGY:[ \t]*)[^\r\n]*'
    if ($raw -match $strategyPattern) {
        $raw = $raw -replace $strategyPattern, "`${1}$Strategy"
    }
    else {
        Write-Warn 'SYNC_STRATEGY not found in template-sync.yml'
    }

    if ($raw -eq $original) {
        Write-Skip 'Template Sync already targets the parent and is scheduled'
        return
    }
    $raw | Set-Content -NoNewline $f
    Write-Ok 'Configured Template Sync'
    Write-Detail "source   : $httpsUrl"
    Write-Detail "strategy : $Strategy"
    # Report the cron the template actually declares rather than assuming a
    # cadence.
    $cron = [regex]::Match($raw, '(?m)^[ \t]*- cron:[ \t]*(.+?)[ \t]*\r?$')
    $cronLine = $cron.Groups[1].Value
    if (-not $cronLine) { $cronLine = '(no cron found)' }
    Write-Detail "schedule : $cronLine"
}

function Remove-ScriptsFolder {
    <#
    .SYNOPSIS
        Deletes the scripts/ folder in a code repo, which isn't derived from.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $dir = Join-Path $RepoPath 'scripts'
    if (Test-Path $dir) {
        Remove-Item $dir -Recurse -Force
        Write-Ok "Removed scripts/ (code repo won't be derived from)"
    }
}

function Write-SettingsFile {
    <#
    .SYNOPSIS
        Writes the minimal _extends settings.yml.
        Kind=Code also sets is_template: false.
    .DESCRIPTION
        Skipped only when the file already names THIS repo.
        Testing for '_extends:' alone would wrongly preserve
        the parent's inherited settings.yml.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][ValidateSet('Template', 'Code')][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExtendsRepo,
        [Parameter(Mandatory)][string]$Description,
        [string]$Homepage,
        [Parameter(Mandatory)][string]$Topics,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )
    $settingsPath = Join-Path $RepoPath '.github/settings.yml'
    if (Test-Path $settingsPath) {
        $existing = Get-Content -Raw $settingsPath
        if ($existing -match "(?m)^\s*name:\s*$([regex]::Escape($Name))\s*$") {
            Write-Skip "settings.yml already targets '$Name'"
            return
        }
    }
    $sep = '  #' + ('─' * 77)
    $repoPluginDoc = '  # https://github.com/repository-settings/app' +
    '/blob/master/docs/plugins/repository.md'
    $lines = [System.Collections.Generic.List[string]]::new()
    @(
        '# Inherit everything from the immediate parent template and override'
        '# only what differs. The Settings app resolves _extends RECURSIVELY,'
        '# so this repo also picks up every ancestor through the chain'
        '# (e.g. .template-dotnet -> .github). Bare repo name = same owner.'
        "_extends: $ExtendsRepo"
        ''
        'repository:'
        $sep
        '  # "About" section (on Home Page)'
        $repoPluginDoc
        '  # https://docs.github.com/en/rest/repos/repos#update-a-repository'
        $sep
        ''
        '  # A short description of the repo'
        '  # MUST BE A SINGLE LINE'
        "  description: $Description"
        ''
        '  # A URL with more information about the repo'
    ) | ForEach-Object { $lines.Add($_) }
    if ($Homepage) { $lines.Add("  homepage: $Homepage") }
    else { $lines.Add('  # homepage: (none)') }
    @(
        ''
        '  # A comma-separated list of topics to set on the repo'
        '  # See https://github.com/topics'
        "  topics: $Topics"
        ''
        $sep
        '  # Settings -> General'
        $repoPluginDoc
        '  # https://docs.github.com/en/rest/repos/repos#update-a-repository'
        $sep
        ''
        '  # The name of the repo'
        "  name: $Name"
    ) | ForEach-Object { $lines.Add($_) }
    # Only stated when it differs from the inherited default, so a repo that
    # is meant to be public never carries a line that could flip it.
    if ($Visibility -eq 'Private') {
        $lines.Add('')
        $lines.Add('  # Visibility')
        $lines.Add('  private: true')
    }
    if ($Kind -eq 'Code') {
        @(
            ''
            '  # Code repo: not a template (override the inherited value)'
            '  is_template: false'
            ''
            $sep
            '  # Settings -> General -> Pull Requests'
            $sep
            ''
            '  # Template layers rebase-merge so their history stays linear'
            '  # and no merge commits propagate downstream. A code repo is'
            '  # derived FROM but never derived from, so it can merge'
            '  # normally: rewrite history in a PR, then merge it as-is.'
            '  allow_merge_commit: true'
            '  allow_squash_merge: false'
            '  allow_rebase_merge: false'
            ''
            $sep
            '  # Settings -> Rules -> Rulesets'
            $sep
            ''
            'rulesets:'
            '  # Only template layers need linear history. Inheritance is'
            '  # additive, so this can be switched off here but never removed.'
            '  - name: Require linear history'
            '    enforcement: disabled'
        ) | ForEach-Object { $lines.Add($_) }
    }
    $settingsDir = Split-Path -Parent $settingsPath
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Force $settingsDir | Out-Null
    }
    $content = ($lines -join "`r`n") + "`r`n"
    Set-Content -Path $settingsPath -Value $content -NoNewline -Encoding utf8
    Write-Ok "Wrote .github/settings.yml ($Kind)"
}

function Rename-Token {
    <#
    .SYNOPSIS
        Replaces a placeholder token in file content, file names,
        and directory names.
    .DESCRIPTION
        Deepest paths first,
        so renaming a parent cannot invalidate its children's paths.
    .PARAMETER SkipExtension
        Binary-ish extensions to leave alone.
    .PARAMETER Exclude
        Directory names to skip entirely: build output, and scripts/ - which
        is where the token is DEFINED and documented rather than used. Renaming
        it there would rewrite $script:DotnetPlaceholder itself, and every
        deeper layer would then rename the wrong word.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [string[]]$SkipExtension = @(
            '.png', '.jpg', '.jpeg', '.gif', '.ico', '.svg',
            '.pdf', '.zip', '.dll', '.exe', '.snk'
        ),
        [string[]]$Exclude = @('.git', 'bin', 'obj', 'node_modules', 'scripts')
    )
    if ($From -eq $To) {
        Write-Skip "Nothing to rename ('$From' is already '$To')"
        return
    }

    $escaped = ($Exclude | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $skipRx = "[\\/]($escaped)[\\/]"
    $all = Get-ChildItem -LiteralPath $RepoPath `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
    $all = @($all | Where-Object { $_.FullName -notmatch $skipRx })

    # 1) content
    $edited = 0
    $files = @($all | Where-Object {
            -not $_.PSIsContainer -and $_.Extension -notin $SkipExtension
        })
    foreach ($f in $files) {
        $raw = Get-Content -LiteralPath $f.FullName -Raw `
            -ErrorAction SilentlyContinue
        if ($null -ne $raw -and $raw.Contains($From)) {
            $updated = $raw.Replace($From, $To)
            Set-Content -LiteralPath $f.FullName -Value $updated -NoNewline
            $edited++
        }
    }

    # 2) names, deepest first
    $renamed = 0
    $depth = { $_.FullName.Split([char]'\').Count }
    $named = $all | Where-Object { $_.Name.Contains($From) }
    $named = @($named | Sort-Object $depth -Descending)
    foreach ($item in $named) {
        # Skip anything a parent rename already moved.
        if (-not (Test-Path -LiteralPath $item.FullName)) { continue }
        Rename-Item -LiteralPath $item.FullName `
            -NewName ($item.Name.Replace($From, $To)) -ErrorAction Stop
        $renamed++
    }

    if ($edited -eq 0 -and $renamed -eq 0) {
        Write-Skip "No '$From' found to rename"
        return
    }
    Write-Ok "Renamed '$From' -> '$To'"
    Write-Detail "$edited file(s) edited, $renamed path(s) renamed"
}

#───────────────────────────────────────────────────────────────────────────────
# Step: VS Code multi-root workspace
#───────────────────────────────────────────────────────────────────────────────

function Get-FolderSettingsBlock {
    <#
    .SYNOPSIS
        Returns .vscode/settings.json's body,
        re-indented for a .code-workspace 'settings' block.
    .DESCRIPTION
        VS Code ignores window-scoped settings coming from folder settings
        while a multi-root workspace is open,
        so they have to be restated in the workspace file.
        Resource-scoped ones still resolve from the folder,
        which outranks this copy,
        so mirroring the whole file is safe
        and avoids hard-coding which keys are window-scoped.
        Spliced as text, not parsed,
        so key order and comments survive.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath
    )
    $path = Join-Path $RepoPath '.vscode\settings.json'
    if (-not (Test-Path $path)) { return @() }

    $text = (Get-Content -LiteralPath $path -Raw).Trim()
    if (-not ($text.StartsWith('{') -and $text.EndsWith('}'))) {
        Write-Warn 'settings.json is not one JSON object; not mirrored'
        return @()
    }

    $body = $text.Substring(1, $text.Length - 2)
    $lines = @($body -split '\r?\n' | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return @() }

    $strip = ($lines |
        ForEach-Object { $_.Length - $_.TrimStart(' ').Length } |
        Measure-Object -Minimum).Minimum
    # Both files indent JSON by two spaces, so the source lines keep their own
    # relative nesting and only need shifting one level deeper.
    return @($lines | ForEach-Object { '    ' + $_.Substring($strip) })
}

function Write-WorkspaceFile {
    <#
    .SYNOPSIS
        Writes a multi-root <repo>.code-workspace,
        spanning the new repo and its template chain.
    .DESCRIPTION
        Paths resolve against this file's own folder,
        so the new repo is "." and its ancestors are "../<name>",
        forward slashes only.
        The new repo is listed first,
        because tooling that is not multi-root aware only sees folders[0].
        dotnet.defaultSolution is window-scoped,
        so it must live in the workspace 'settings' block;
        it is ignored per-folder.
    .PARAMETER ChainPaths
        Ancestor template paths, nearest first.
    .PARAMETER Force
        Overwrites an existing workspace file, instead of leaving edits alone.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RepoName,
        [string[]]$ChainPaths = @(),
        [switch]$Force
    )
    $repoFull = (Resolve-Path $RepoPath).Path
    $wsPath = Join-Path $repoFull "$RepoName.code-workspace"
    if ((Test-Path $wsPath) -and -not $Force) {
        Write-Skip "$RepoName.code-workspace already exists"
        return $wsPath
    }

    # ── folders: primary repo first, then each ancestor as a sibling relative
    # path ──
    $folders = [System.Collections.Generic.List[string]]::new()
    $folders.Add(
        '    // The new repo. Listed first so it is folders[0], the primary.')
    $folders.Add("    { `"name`": `"$RepoName`", `"path`": `".`" },")
    if ($ChainPaths.Count -gt 0) {
        $folders.Add(
            '    // Template layers inherited from, nearest parent first.')
        foreach ($p in $ChainPaths) {
            $name = Split-Path -Leaf $p
            $full = (Resolve-Path $p).Path
            $rel = [System.IO.Path]::GetRelativePath($repoFull, $full)
            $rel = $rel -replace '\\', '/'
            $folders.Add("    { `"name`": `"$name`", `"path`": `"$rel`" },")
        }
    }

    # Pin the primary repo's solution,
    # or C# Dev Kit adopts a template layer's placeholder one -
    # or prompts on every open when it finds several.
    $slns = Get-ChildItem -LiteralPath $repoFull `
        -Include *.sln, *.slnx, *.slnf `
        -File `
        -Recurse `
        -Depth 3 `
        -ErrorAction SilentlyContinue
    $slns = $slns | Where-Object {
        $_.FullName -notmatch '[\\/](bin|obj|node_modules|\.git)[\\/]'
    }
    $slns = @($slns | Sort-Object FullName)

    $mirrored = Get-FolderSettingsBlock -RepoPath $repoFull
    $comma = if ($mirrored.Count -gt 0) { ',' } else { '' }

    $settings = [System.Collections.Generic.List[string]]::new()
    if ($slns.Count -gt 0) {
        $sln = $slns[0].FullName.Substring($repoFull.Length)
        $rel = $sln.TrimStart('\', '/') -replace '\\', '/'
        if ($slns.Count -gt 1) {
            $settings.Add(
                "    // $($slns.Count) solutions found; pinned the first.")
        }
        $settings.Add(
            '    // Relative to folders[0]. Forward slashes required.')
        $settings.Add("    `"dotnet.defaultSolution`": `"$rel`"$comma")
    }
    else {
        $settings.Add(
            "    // No solution yet. 'disable' stops C# Dev Kit from adopting")
        $settings.Add(
            "    // a TEMPLATE layer's, and silences the 'open solution' nag.")
        $settings.Add(
            "    // Replace with e.g. `"MyRepo.sln`" once you add one.")
        $settings.Add("    `"dotnet.defaultSolution`": `"disable`"$comma")
    }
    if ($mirrored.Count -gt 0) {
        $settings.Add('')
        $settings.Add(
            '    // Mirrored from .vscode/settings.json, because VS Code ignores')
        $settings.Add(
            '    // window-scoped folder settings in a multi-root workspace.')
        $mirrored | ForEach-Object { $settings.Add($_) }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    @(
        '{'
        "  // Multi-root workspace for $RepoName and its template layers."
        '  // Generated by the scaffolding scripts; local-only.'
        '  // Safe to edit or delete - it is never regenerated over edits.'
        "  `"folders`": ["
    ) | ForEach-Object { $lines.Add($_) }
    $folders | ForEach-Object { $lines.Add($_) }
    @(
        '  ],'
        "  `"settings`": {"
    ) | ForEach-Object { $lines.Add($_) }
    $settings | ForEach-Object { $lines.Add($_) }
    @(
        '  }'
        '}'
    ) | ForEach-Object { $lines.Add($_) }

    $content = ($lines -join "`r`n") + "`r`n"
    Set-Content -Path $wsPath -Value $content -NoNewline -Encoding utf8
    Add-Change
    Write-Ok "Wrote $RepoName.code-workspace ($(1 + $ChainPaths.Count) folders)"
    return $wsPath
}

function Start-VSCode {
    <#
    .SYNOPSIS
        Opens a path in VS Code as a separate, detached process.
    .DESCRIPTION
        The path can be a folder or a .code-workspace.

        Prefers Code.exe over the code.cmd shim:
        launching the .cmd through Start-Process flashes a console window,
        while the exe returns immediately and cleanly.
        Falls back to the shim, then to Insiders.
        Never throws - failing to open an editor
        should not fail a successful scaffold.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [switch]$NewWindow
    )
    $exe = $null

    # Derive Code.exe from the shim on PATH:
    # <root>\bin\code.cmd -> <root>\Code.exe
    foreach ($cliName in 'code', 'code-insiders') {
        $cli = Get-Command $cliName -ErrorAction SilentlyContinue
        if (-not $cli) { continue }
        $shim = $cli.Source
        $exeName = if ($cliName -eq 'code-insiders') {
            'Code - Insiders.exe'
        }
        else { 'Code.exe' }
        $root = Split-Path -Parent (Split-Path -Parent $shim)
        $candidate = Join-Path $root $exeName
        if (Test-Path $candidate) { $exe = $candidate; break }
        $exe = $shim; break      # shim works too, just less tidy
    }
    if (-not $exe) {
        foreach ($p in @(
                "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
                "$env:ProgramFiles\Microsoft VS Code\Code.exe",
                "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe"
            )) {
            if (Test-Path $p) { $exe = $p; break }
        }
    }
    if (-not $exe) {
        Write-Warn "VS Code CLI not found - open it yourself: $Target"
        return
    }

    $argList = @()
    if ($NewWindow) { $argList += '-n' }
    $argList += $Target
    try {
        Start-Process -FilePath $exe -ArgumentList $argList | Out-Null
        Write-Ok "Opening in VS Code: $(Split-Path -Leaf $Target)"
    }
    catch {
        Write-Warn ("Couldn't launch VS Code ($($_.Exception.Message)) - " +
            "open it yourself: $Target")
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Step: commit / push / workflows
#───────────────────────────────────────────────────────────────────────────────

function Test-CommitSubject {
    <#
    .SYNOPSIS
        Returns true if THIS repo already made a commit with this exact subject.
    .DESCRIPTION
        Scoped to template/<branch>..HEAD.
        Searching all history would match the same commits
        inherited from an already-scaffolded parent,
        and skip customizing the new repo entirely.
        Returns false when the template ref is missing,
        so the step re-runs harmlessly.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message
    )
    $ref = "template/$($script:TemplateBranch)"
    git -C $RepoPath rev-parse --verify --quiet $ref | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0   # no template ref yet
        return $false
    }

    # Exact subject match, so one group's message can't satisfy another's
    # gate by prefix.
    # A reverted step still reads as done,
    # since the original subject remains in the range.
    $subjects = git -C $RepoPath log --format='%s' "$ref..HEAD" 2>$null
    return [bool](@($subjects) -ceq $Message)
}

function Get-DirtyPath {
    <#
    .SYNOPSIS
        Returns the paths git currently reports as changed, one per entry.
    .DESCRIPTION
        A rename shows up as 'R old -> new'; BOTH sides are returned,
        because staging only the new path would leave the deletion
        of the old one out of the commit.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $lines = @(git -C $RepoPath status --porcelain 2>$null)
    $global:LASTEXITCODE = 0
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line.Length -le 3) { continue }
        $rest = $line.Substring(3)
        foreach ($p in ($rest -split ' -> ')) {
            $t = $p.Trim().Trim('"')
            if ($t) { $paths.Add($t) }
        }
    }
    return $paths.ToArray()
}

function Invoke-GatedCommit {
    <#
    .SYNOPSIS
        Runs a group of related changes and commits them,
        unless that commit already exists.
    .DESCRIPTION
        $Message is both the commit subject and the idempotency key,
        so rewording one silently makes an already-scaffolded repo
        look unscaffolded.
    .PARAMETER Paths
        Pathspec to stage.
        Omit it to stage exactly what -Body changed,
        which is what you want for anything repo-wide.
        Either way your own uncommitted work is excluded.
    .PARAMETER Body
        Scriptblock; it still sees the calling script's variables.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Paths,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    if (Test-CommitSubject -RepoPath $RepoPath -Message $Message) {
        Write-Skip "'$Message' already in history"
        return
    }

    if ($Paths) {
        & $Body
        Invoke-StagedCommit -RepoPath $RepoPath -Message $Message `
            -Paths $Paths
        return
    }

    # No -Paths: stage exactly what the body touched.
    # A hand-maintained list would silently omit files
    # that a repo-wide rename moved.
    $before = @(Get-DirtyPath -RepoPath $RepoPath)
    & $Body
    $after = @(Get-DirtyPath -RepoPath $RepoPath)
    $touched = @($after | Where-Object { $_ -notin $before })
    if (-not $touched) { Write-Skip "Nothing changed for: $Message"; return }
    Invoke-StagedCommit -RepoPath $RepoPath -Message $Message -Paths $touched
}

function Invoke-StagedCommit {
    <#
    .SYNOPSIS
        Stages the paths this group owns and commits,
        but only if something is actually staged.
    .DESCRIPTION
        -Paths is a deliberate safety boundary.
        Staging everything ('git add -A') is unsafe on a re-run:
        if a group legitimately produces no diff,
        because the parent template already did that work,
        then no commit is made, its gate stays false,
        and the group runs again on every future run -
        sweeping a developer's unrelated uncommitted work
        into a 'chore:' commit.
        Scoping the pathspec makes an ungated no-diff group harmless.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Paths = @('.')
    )
    # 'git add -- <path>' is a hard error
    # when the path is neither on disk nor tracked, so drop those first -
    # e.g. scripts/ in a template repo, which is untouched.
    $spec = @($Paths | Where-Object {
            if (Test-Path (Join-Path $RepoPath $_)) { return $true }
            git -C $RepoPath ls-files --error-unmatch -- $_ 2>&1 | Out-Null
            $tracked = ($LASTEXITCODE -eq 0)
            $global:LASTEXITCODE = 0
            return $tracked
        })
    if (-not $spec) { Write-Skip "Nothing to stage for: $Message"; return }

    Invoke-Git -What 'Staging changes' -RepoPath $RepoPath `
        -Arguments (@('add', '-A', '--') + $spec) | Out-Null
    git -C $RepoPath diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        # Summarise what is going in BEFORE committing,
        # so the log shows the grouping.
        $staged = @(git -C $RepoPath diff --cached --name-status 2>$null)
        Invoke-Git -What "Committing '$Message'" -RepoPath $RepoPath `
            -Arguments @('commit', '-m', $Message) | Out-Null
        Add-Change
        Write-Ok "Committed: $Message"
        foreach ($line in $staged) {
            $parts = $line -split "`t", 2
            if ($parts.Count -eq 2) {
                Write-Detail ('{0}  {1}' -f $parts[0].PadRight(2), $parts[1])
            }
        }
    }
    else {
        Write-Skip "Nothing to commit for: $Message"
    }
}

function Push-Repo {
    <#
    .SYNOPSIS
        Pushes main. Idempotent: 'Everything up-to-date' when nothing changed.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)
    $out = Invoke-Git -What 'Pushing main' -RepoPath $RepoPath `
        -Arguments @('push', '-u', 'origin', 'main')
    if (($out | Out-String) -match 'Everything up-to-date') {
        Write-Skip 'main already up to date on the remote'
    }
    else {
        Write-Ok 'Pushed main'
        Write-Detail "the 'Settings' app applies settings.yml in a few minutes"
    }
}

function Get-WorkflowRunId {
    <#
    .SYNOPSIS
        Returns the run IDs a workflow currently has, newest first.
    .DESCRIPTION
        Used to tell a run we just dispatched apart from earlier ones,
        because `gh workflow run` does not report the ID it created.
    #>
    param(
        [Parameter(Mandatory)][string]$OwnerRepo,
        [Parameter(Mandatory)][string]$Workflow
    )
    $ghArgs = @(
        'run', 'list'
        '--repo', $OwnerRepo
        '--workflow', $Workflow
        '--limit', '20'
        '--json', 'databaseId'
        '--jq', '.[].databaseId'
    )
    $ids = & gh @ghArgs 2>$null
    $global:LASTEXITCODE = 0
    return @($ids | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Start-TemplateSync {
    <#
    .SYNOPSIS
        Dispatches the Template Sync workflow, and returns the runs that
        already existed so Wait-TemplateSync can spot the new one.
    .DESCRIPTION
        Returns $null when the dispatch itself failed, which is the signal
        not to wait for anything.
    #>
    param([Parameter(Mandatory)][string]$OwnerRepo)

    $before = Get-WorkflowRunId -OwnerRepo $OwnerRepo `
        -Workflow 'template-sync.yml'

    $ghArgs = @(
        'workflow', 'run', 'template-sync.yml'
        '--repo', $OwnerRepo
        '--ref', 'main'
    )
    & gh @ghArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        Write-Warn ('Could not dispatch Template Sync yet ' +
            '(the workflow may still be registering)')
        Write-Detail "run it from https://github.com/$OwnerRepo/actions"
        return $null
    }

    Add-Change
    Write-Ok 'Dispatched Template Sync'
    return @{ PriorRunId = $before }
}

function Wait-TemplateSync {
    <#
    .SYNOPSIS
        Waits for the dispatched Template Sync run, then checks it did nothing.
    .DESCRIPTION
        A freshly scaffolded repo is already a descendant of its template, so
        the merge has nothing to apply. Success therefore means BOTH that the
        run passed AND that it opened no pull request. A PR here means the new
        repo's tree diverges from the template in some way scaffolding did not
        account for - worth looking at by hand.

        Never throws. A broken sync does not make the repo any less created,
        so this warns and prints where to look. The warning still lands in the
        end-of-run tally.
    .PARAMETER Handle
        What Start-TemplateSync returned. $null means the dispatch failed.
    .PARAMETER TimeoutSeconds
        How long to wait for the run to finish. The workflow is a checkout,
        a fetch and a diff, so it is normally well under a minute.
    #>
    param(
        [Parameter(Mandatory)][string]$OwnerRepo,
        [AllowNull()]$Handle,
        [int]$TimeoutSeconds = 300,
        [int]$PollSeconds = 5
    )
    if (-not $Handle) { return }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $runId = $null

    # The run does not exist the instant the dispatch returns.
    Write-Detail 'waiting for the run to appear'
    while (-not $runId -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $now = Get-WorkflowRunId -OwnerRepo $OwnerRepo `
            -Workflow 'template-sync.yml'
        $fresh = @($now | Where-Object { $_ -notin $Handle.PriorRunId })
        $runId = $fresh | Select-Object -First 1
    }
    if (-not $runId) {
        Write-Warn 'Template Sync did not start within the timeout'
        Write-Detail "check https://github.com/$OwnerRepo/actions"
        return
    }

    $runUrl = "https://github.com/$OwnerRepo/actions/runs/$runId"
    Write-Detail "run $runId - waiting for it to finish"

    $status = ''
    $conclusion = ''
    while ((Get-Date) -lt $deadline) {
        $ghArgs = @(
            'run', 'view', $runId
            '--repo', $OwnerRepo
            '--json', 'status,conclusion'
            '--jq', '.status + "|" + (.conclusion // "")'
        )
        $raw = (& gh @ghArgs 2>$null | Out-String).Trim()
        $global:LASTEXITCODE = 0
        if ($raw -match '^(?<s>[^|]*)\|(?<c>.*)$') {
            $status = $Matches['s']
            $conclusion = $Matches['c']
        }
        if ($status -eq 'completed') { break }
        Start-Sleep -Seconds $PollSeconds
    }

    if ($status -ne 'completed') {
        Write-Warn "Template Sync was still $status after ${TimeoutSeconds}s"
        Write-Detail $runUrl
        return
    }
    if ($conclusion -ne 'success') {
        Write-Warn "Template Sync finished as '$conclusion' - needs a look"
        Write-Detail $runUrl
        return
    }

    # Success criterion #2: it should have found nothing to sync.
    $ghArgs = @(
        'pr', 'list'
        '--repo', $OwnerRepo
        '--head', 'template-sync'
        '--state', 'open'
        '--json', 'number,title'
        '--jq', '.[] | "#\(.number) \(.title)"'
    )
    $prs = @(& gh @ghArgs 2>$null | Where-Object { $_ })
    $global:LASTEXITCODE = 0

    if ($prs) {
        Write-Warn "Template Sync opened $($prs.Count) pull request(s)"
        Write-Detail 'a fresh repo should have nothing to sync; review these:'
        foreach ($pr in $prs) { Write-Detail $pr }
        Write-Detail "https://github.com/$OwnerRepo/pulls"
        return
    }

    Write-Ok 'Template Sync ran clean, with nothing to sync'
    Write-Detail $runUrl
}

#───────────────────────────────────────────────────────────────────────────────
# Exports
#───────────────────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    # Logging vocabulary - part of the contract; the scripts use these directly.
    'Write-Ok'
    'Write-Skip'
    'Write-Warn'
    'Write-Err'
    'Write-Info'
    'Write-Detail'

    'Get-RepoOwner'
    'Get-TemplateBranch'
    'Write-Step'
    'Write-Field'
    'Show-Summary'
    'Show-Failure'
    'Invoke-GatedCommit'
    'Invoke-LayerModule'
    'Rename-Token'
    'Get-DirtyPath'
    'Get-LayerModule'
    'Import-LayerModule'
    'Remove-LayerModule'
    'Add-Change'
    'Get-ChangeCount'
    'Add-ManualItem'
    'Register-ManualSetting'
    'Show-ManualChecklist'
    'Get-TemplateContext'
    'Get-ActiveGhAccount'
    'Use-GhAccount'
    'Reset-GhAccount'
    'New-GitHubRepo'
    'Set-WorkflowPermission'
    'Enable-PrivateVulnReporting'
    'Set-RepoSecret'
    'Set-RepoVariable'
    'Initialize-Topic'
    'Enable-ReleaseImmutability'
    'Add-CodeqlLanguage'
    'Get-CodeqlLanguage'
    'Enable-Codeql'
    'Get-NewRepoUrl'
    'Get-TemplateChain'
    'Initialize-Clone'
    'Test-CommitSubject'
    'Remove-TemplateOnlyFile'
    'Update-RepoReference'
    'Update-Readme'
    'Update-ReadmeDiagram'
    'Set-ReadmeTitle'
    'Reset-Readme'
    'Set-RepoLicense'
    'Set-TemplateSyncConfig'
    'Remove-ScriptsFolder'

    'Write-WorkspaceFile'
    'Start-VSCode'
    'Write-SettingsFile'
    'Invoke-StagedCommit'
    'Push-Repo'
    'Start-TemplateSync'
    'Wait-TemplateSync'
    'Get-WorkflowRunId'
)
