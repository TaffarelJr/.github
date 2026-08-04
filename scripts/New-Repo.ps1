#Requires -Version 7.0
<#
.SYNOPSIS
    Create a new code repo derived from THIS template repo.

.DESCRIPTION
    Run this from inside the template repo you want to derive from.
    The source template is auto-detected from this repo's 'origin' remote;
    the new repo is created on GitHub and cloned next to this one,
    reusing the same 'origin' URL style.

    Same flow as New-TemplateRepo.ps1, with three differences: the repo name is freeform
    (no '.template-' prefix), settings.yml overrides is_template to false, and the
    scripts/ folder is removed - a code repo isn't derived from, and external
    contributors have no use for the personal templating infrastructure.

    Scaffolding produces a complete, known-good baseline and stops. Its work is grouped
    into separate commits (template files, then repo settings), but it never pauses for
    you to add repo-specific customizations along the way - those are just normal commits
    you make afterwards, on a branch, as a PR.

    Every value is an OPTIONAL parameter.
    Anything you omit is prompted for, with a sensible default where one exists.
    Supply all of them plus -SkipManualPrompts for a fully unattended run.

    Idempotent & resumable: re-running verifies what's already done,
    and only fills gaps. It never overwrites post-scaffold changes.

.PARAMETER Name
    New repo name (kebab-case), e.g. 'my-service'.
.PARAMETER GhAccount
    gh account that admins the owner. Switched to & verified first. Blank = use current.
.PARAMETER Description
    settings.yml description (single line).
.PARAMETER Homepage
    settings.yml homepage URL. Empty = omit.
.PARAMETER Topics
    settings.yml topics (comma-separated).
.PARAMETER CodecovToken
    CODECOV_TOKEN secret value. Empty = skip. Prompted without echo when omitted.
.PARAMETER TemplateBranch
    Branch on the template remote to base 'main' on. Default: main.
.PARAMETER SkipManualPrompts
    Skip all interactive prompts and the confirmation gate (unattended runs).

.EXAMPLE
    ./scripts/New-Repo.ps1                            # fully interactive
.EXAMPLE
    ./scripts/New-Repo.ps1 -Name my-service           # prompts only for the rest
.EXAMPLE
    ./scripts/New-Repo.ps1 -Name my-service -GhAccount TaffarelJr `
        -Description 'My service' -Homepage '' -Topics 'dotnet, service' `
        -CodecovToken $env:CODECOV -SkipManualPrompts   # unattended
#>
[CmdletBinding()]
param(
    [string]$Name,
    [string]$GhAccount,
    [string]$Description,
    [string]$Homepage,
    [string]$Topics,
    [string]$CodecovToken,
    [string]$TemplateBranch = 'main',
    [switch]$SkipManualPrompts
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RepoScaffolding.psm1') -Force
Set-ScaffoldSkipPrompts $SkipManualPrompts.IsPresent
$bound = $PSBoundParameters

# Render any terminating error as a readable banner (which step, message, stack) instead of
# a raw PowerShell dump, then stop with a non-zero exit code.
trap { Show-ScaffoldFailure -ErrorRecord $_; exit 1 }

# ── Step 0: context + inputs ──────────────────────────────────────────────────
Write-ScaffoldStep '0' 'Prerequisites & inputs'
$ctx = Get-ScaffoldContext -ScriptRoot $PSScriptRoot
$owner = Get-ScaffoldOwner

$Name = Resolve-ScaffoldValue -Name Name -Bound $bound -Value $Name -Prompt "New repo name (kebab-case, e.g. 'my-service')"
$Name = Format-ScaffoldSlug -Value $Name -Label 'Name'

$repo = $Name
$ownerRepo = "$owner/$repo"
$targetPath = Join-Path $ctx.ParentDir $repo

Write-ScaffoldField 'Source template' $ctx.SourceOwnerRepo
Write-ScaffoldField ''                $ctx.SourceRoot
Write-ScaffoldField 'New code repo'   $ownerRepo
Write-ScaffoldField 'Clone to'        $targetPath

$GhAccount = Resolve-ScaffoldValue -Name GhAccount -Bound $bound -Value $GhAccount -Prompt "gh account that admins '$owner' (blank = use current)"
Confirm-ScaffoldGhAccount -GhAccount $GhAccount -ProbeOwnerRepo $ctx.SourceOwnerRepo

$Description = Resolve-ScaffoldValue -Name Description -Bound $bound -Value $Description -Prompt 'Repo description (single line)'
$Homepage = Resolve-ScaffoldValue -Name Homepage    -Bound $bound -Value $Homepage    -Prompt 'Homepage URL (optional - blank to omit)'
$Topics = Resolve-ScaffoldValue -Name Topics      -Bound $bound -Value $Topics      -Prompt 'Topics (comma-separated)'

if (-not $bound.ContainsKey('CodecovToken')) {
    Write-ScaffoldField 'Codecov token at' "https://app.codecov.io/account/gh/$owner/org-upload-token"
}
$CodecovToken = Resolve-ScaffoldValue -Name CodecovToken -Bound $bound -Value $CodecovToken -Prompt 'CODECOV_TOKEN value (blank to skip)' -Secret

if (-not (Confirm-ScaffoldProceed -OwnerRepo $ownerRepo)) { return }

# ── Step 1: create ────────────────────────────────────────────────────────────
Write-ScaffoldStep '1' 'Create the new repo'
New-ScaffoldRepo -OwnerRepo $ownerRepo

# ── Step 2: settings (API) ────────────────────────────────────────────────────
Write-ScaffoldStep '2' 'Configure repo settings (API)'
Set-ScaffoldActionsPermissions      -OwnerRepo $ownerRepo
Enable-ScaffoldPrivateVulnReporting -OwnerRepo $ownerRepo
Enable-ScaffoldImmutableReleases    -OwnerRepo $ownerRepo
Set-ScaffoldCodecovSecret           -OwnerRepo $ownerRepo -Token $CodecovToken

# ── Step 3: clone + remotes ───────────────────────────────────────────────────
Write-ScaffoldStep '3' 'Clone the new repo'
$originUrl = Get-ScaffoldSiblingUrl -Context $ctx -RepoName $repo   # preserves origin style
Initialize-ScaffoldClone -OriginUrl $originUrl -TargetPath $targetPath -TemplateUrl $ctx.SourceUrl -TemplateBranch $TemplateBranch

# ── Step 4: drop what belongs only to the parent ──────────────────────────────
# Deletions run BEFORE the README pass, so the README stops documenting files that
# have already gone rather than the other way round.
Write-ScaffoldStep '4' 'Remove template-only files'
Invoke-ScaffoldGatedCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch `
    -Message 'chore: remove template-only files' -Paths @('.github', 'README.md', 'scripts') -Body {
    Remove-ScaffoldTemplateOnlyFiles -RepoPath $targetPath
    Remove-ScaffoldScripts           -RepoPath $targetPath
    Update-ScaffoldReadme            -RepoPath $targetPath
}

# ── Step 5: point this repo's docs at itself ──────────────────────────────────
Write-ScaffoldStep '5' 'Retarget template references'
Invoke-ScaffoldGatedCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch `
    -Message 'chore: retarget template references' `
    -Paths @('.github/ISSUE_TEMPLATE', 'CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md') -Body {
    Update-ScaffoldReferences -RepoPath $targetPath -OldOwnerRepo $ctx.SourceOwnerRepo -NewOwnerRepo $ownerRepo
}

# ── Step 6: start syncing from the immediate parent ───────────────────────────
Write-ScaffoldStep '6' 'Enable Template Sync'
Invoke-ScaffoldGatedCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch `
    -Message 'ci: enable the template sync schedule' `
    -Paths @('.github/workflows/template-sync.yml') -Body {
    Set-ScaffoldTemplateSyncConfig -RepoPath $targetPath -TemplateOwnerRepo $ctx.SourceOwnerRepo
}

# ── Step 7: this repo's own settings ──────────────────────────────────────────
Write-ScaffoldStep '7' 'Customize repo settings'
Invoke-ScaffoldGatedCommit -RepoPath $targetPath -TemplateBranch $TemplateBranch `
    -Message 'chore: customize repo settings' -Paths @('.github/settings.yml') -Body {
    # Inherit from the repo we derived from (_extends resolves recursively up the chain).
    Write-ScaffoldSettings -RepoPath $targetPath -Kind Code -Name $repo `
        -ExtendsRepo $ctx.SourceRepo `
        -Description $Description -Homepage $Homepage -Topics $Topics
}

# ── Step 8: push (triggers Settings app) + CodeQL ─────────────────────────────
Write-ScaffoldStep '8' 'Push & enable CodeQL'
Push-ScaffoldRepo     -RepoPath $targetPath
Enable-ScaffoldCodeql -OwnerRepo $ownerRepo   # now that code/workflows exist

# ── Step 9: initialize workflows (only if something changed this run) ─────────
Write-ScaffoldStep '9' 'Initialize Template Sync'
if ((Get-ScaffoldActivity) -gt 0) {
    Start-ScaffoldTemplateSync -OwnerRepo $ownerRepo
}
else {
    Write-Skip 'Nothing changed this run - Template Sync is already initialized'
}

# ── Step 10: VS Code multi-root workspace, then open it ───────────────────────
Write-ScaffoldStep '10' 'Set up the VS Code workspace'
# Exclude BEFORE creating: if the run dies between the two, an unexcluded workspace file
# would be swept into a later scaffold commit and then sync into every descendant.
Add-ScaffoldGitExclude -RepoPath $targetPath -Pattern "$repo.code-workspace"
# Chain = the source template plus every ancestor cloned locally, nearest first.
$chain = Get-ScaffoldTemplateChain -StartRepoPath $ctx.SourceRoot -ParentDir $ctx.ParentDir
$wsFile = Write-ScaffoldWorkspaceFile -RepoPath $targetPath -RepoName $repo -ChainPaths $chain
Start-ScaffoldVSCode   -Target $wsFile

# ── Manual follow-up checklist ────────────────────────────────────────────────
Register-ScaffoldManualSettings -OwnerRepo $ownerRepo
Show-ScaffoldManualChecklist    -OwnerRepo $ownerRepo
Show-ScaffoldSummary

if ((Get-ScaffoldActivity) -eq 0) {
    Write-Host "  ✅ $ownerRepo was already fully scaffolded - nothing to change." -ForegroundColor Green
}
else {
    Write-Host "  🎉 Code repo $ownerRepo ready at $targetPath." -ForegroundColor Green
}
Write-Host ""
