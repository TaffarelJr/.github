#Requires -Version 7.0

<#
.SYNOPSIS
    Creates a new repo derived from THIS template repo -
    either another TEMPLATE layer or a plain CODE repo.

.DESCRIPTION
    Run this from inside the template repo you want to derive from.
    The source template is auto-detected from this repo's 'origin' remote;
    the new repo is created on GitHub and cloned next to this one,
    reusing the same 'origin' URL style.

    The Kind's defining difference is what a derived repo can do next:
      Template : keeps scripts/ (the child can spawn its own children);
                 is_template stays inherited.
      Code     : removes scripts/ (nothing is derived from a code repo,
                 and outside contributors have no use for the personal
                 templating infrastructure) and sets is_template: false.
    Several later steps also branch on it - the README (replaced for Code,
    de-linked for Template), the retitle step (Template only), the
    settings.yml merge-commit block (Code only), and Template Sync's
    strategy (rebase for Template, merge for Code).

    Scaffolding produces a complete, known-good baseline and stops.
    Its work is grouped into cohesive commits, each with a single concern.
    It never pauses for you to add repo-specific customizations -
    those are normal commits you make afterwards, on a branch, as a PR
    (also required: once the Settings app applies the rulesets,
    direct pushes to main are rejected).

    Every value is prompted for - there are no command-line parameters to
    supply instead, so a template layer can always add its own prompt but can
    never add a parameter to this inherited script. The three secret tokens
    are the one exception: each is read from its environment variable first
    (CODECOV_TOKEN, COPILOT_PAT, TEMPLATE_SYNC_PAT), so setting one up is a
    one-time task rather than something typed in on every run.

    Idempotent & resumable: re-running verifies what's already done
    and only fills gaps. It never overwrites post-scaffold changes.

.EXAMPLE
    ./scripts/New-Repo.ps1
    Prompts for everything - Kind, Name, Visibility, Description, Homepage,
    Topics, and the three tokens (skipped for any already set as an
    environment variable).
#>

# Strict mode here too, not just in the modules. This script holds the loose
# variables - $ctx, $slug, $ownerRepo, $targetPath - and PowerShell treats a
# misspelt one as $null rather than an error, so a typo would quietly scaffold
# the wrong thing.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -Force, so an edit to a module is picked up on the next run in the same
# session.
#
# Every module in this folder is loaded, EXCEPT a tier-numbered layer -
# New-Repo-<NN>-<slug>.psm1 - which Invoke-LayerModule loads on its own, later
# and in tier order. Dropping in a new Common-*.psm1, or splitting one into
# several, is never a reason to edit this script: whatever qualifies is picked
# up by pattern, not by name. Keep the pattern below in step with
# Common-Plugin.psm1's $script:LayerModulePrefix - it has to make the same
# distinction from the opposite side.
$layerModulePattern = '^New-Repo-\d+-.+\.psm1$'
$modules = Get-ChildItem -Path $PSScriptRoot -Filter '*.psm1' -File |
    Where-Object { $_.Name -notmatch $layerModulePattern } |
    Sort-Object Name
foreach ($module in $modules) { Import-Module $module.FullName -Force }

# Show terminating errors as a readable banner, not a raw PowerShell dump.
# Cleanup - releasing the borrowed gh token, unloading the layer modules -
# lives in the `finally` below, not here: this only reports what went wrong.
trap {
    # -Resumable, because every step is idempotent: the banner can honestly
    # tell the reader to re-run rather than to clean up first.
    Show-Failure -ErrorRecord $_ -Activity 'SCAFFOLDING' -Resumable
    exit 1
}

try {
    #───────────────────────────────────────────────────────────────────────────────
    # Step 0: context + inputs
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '0' 'Prerequisites & inputs'
    $ctx = Get-TemplateContext -ScriptRoot $PSScriptRoot
    $owner = Get-RepoOwner

    $Kind = Resolve-Input -Name Kind `
        -Prompt 'Kind' `
        -Choice 'Template', 'Code' `
        -Default 'Code' `
        -Require

    $namePrompt = if ($Kind -eq 'Template') {
        "Template type (kebab-case, e.g. 'dotnet' -> '.template-dotnet')"
    }
    else {
        "New repo name (kebab-case, e.g. 'my-service')"
    }

    $Name = Resolve-Input -Name Name `
        -Prompt $namePrompt `
        -Pattern (Get-SlugPattern) `
        -Requirement (Get-SlugRequirement) `
        -Require

    # Accept either 'dotnet' or '.template-dotnet' for a template layer.
    $slug = if ($Kind -eq 'Template') {
        $Name -replace '^\.template-', ''
    }
    else { $Name }
    $slug = Format-Slug -Value $slug -Label 'Name'
    $repo = if ($Kind -eq 'Template') { ".template-$slug" } else { $slug }

    $ownerRepo = "$owner/$repo"
    $targetPath = Join-Path $ctx.ParentDir $repo

    Write-Field 'Source template' $ctx.SourceOwnerRepo
    Write-Field ''                $ctx.SourceRoot
    Write-Field "New $($Kind.ToLowerInvariant()) repo" $ownerRepo
    Write-Field 'Clone to'        $targetPath

    Use-GhAccount -ProbeOwnerRepo $ctx.SourceOwnerRepo

    $Visibility = Resolve-Input -Name Visibility `
        -Prompt 'Visibility' `
        -Choice 'Public', 'Private' `
        -Default 'Public' `
        -Require

    $Description = Resolve-Input -Name Description `
        -Prompt 'Repo description' `
        -Pattern '^[^\r\n]{1,350}$' `
        -Requirement 'must be a single line of 350 characters or fewer' `
        -Require

    $Homepage = Resolve-Input -Name Homepage `
        -Prompt 'Homepage URL (optional - blank to omit)' `
        -Pattern '^https?://\S+$' `
        -Requirement 'must be an http(s) URL, or blank'

    $Topics = Resolve-Input -Name Topics `
        -Prompt 'Topics (comma-separated - blank to omit)' `
        -Validate { param($v) Get-TopicListError -Value $v }
    $Topics = Format-TopicList -Value $Topics -Label 'Topics'

    # Each of these is the same value for every repo, so the environment is the
    # natural home for it. The hints only appear when one is actually missing.
    $CodecovToken = Resolve-Input -Name CodecovToken `
        -Prompt 'CODECOV_TOKEN value (blank to skip)' `
        -EnvVar 'CODECOV_TOKEN' `
        -Hint "Codecov token at https://app.codecov.io/account/gh/$owner/org-upload-token" `
        -Secret

    $CopilotToken = Resolve-Input -Name CopilotToken `
        -Prompt 'COPILOT_PAT value (blank to skip)' `
        -EnvVar 'COPILOT_PAT' `
        -Hint 'Copilot PAT at https://github.com/settings/personal-access-tokens', `
        'Drafts the release-notes summary; without it the notes get a placeholder' `
        -Secret

    $TemplateSyncToken = Resolve-Input -Name TemplateSyncToken `
        -Prompt 'TEMPLATE_SYNC_PAT value (blank to skip)' `
        -EnvVar 'TEMPLATE_SYNC_PAT' `
        -Hint 'Template Sync PAT at https://github.com/settings/personal-access-tokens', `
        'One token for every repo. Without it, sync PRs get no CI' `
        -Secret

    if (-not (Confirm-Proceed -Action "create/verify $ownerRepo")) { return }

    #───────────────────────────────────────────────────────────────────────────────
    # Step 1: create
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '1' 'Create the new repo'
    # Reassigned to the ACTUAL visibility: an existing repo's is never changed,
    # so a resumed run answering -Visibility differently than the run that
    # created it must follow GitHub's answer, not its own, for everything after.
    $Visibility = New-GitHubRepo -OwnerRepo $ownerRepo -Visibility $Visibility

    #───────────────────────────────────────────────────────────────────────────────
    # Step 2: settings (API)
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '2' 'Configure repo settings (API)'
    Set-WorkflowPermission      -OwnerRepo $ownerRepo
    Enable-PrivateVulnReporting -OwnerRepo $ownerRepo
    Enable-ReleaseImmutability  -OwnerRepo $ownerRepo
    Initialize-Topic            -OwnerRepo $ownerRepo
    Set-RepoSecret              -OwnerRepo $ownerRepo -Token $CodecovToken `
        -Name CODECOV_TOKEN

    # Template Sync reads its parent and its strategy from the repo rather than
    # from the workflow file, so that file stays byte-identical at every layer and
    # a parent's edit to it can never conflict. Retargeting matters: a level-2 repo
    # would otherwise keep syncing from its GRANDparent. Only a leaf records merge
    # commits; a template layer rebases, so its history stays linear and its own
    # merge commits never reach a leaf.
    Set-RepoVariable -OwnerRepo $ownerRepo -Name TEMPLATE_REPO_URL `
        -Value "https://github.com/$($ctx.SourceOwnerRepo).git"
    Set-RepoVariable -OwnerRepo $ownerRepo -Name TEMPLATE_SYNC_STRATEGY `
        -Value $(if ($Kind -eq 'Code') { 'merge' } else { 'rebase' })

    if ($CopilotToken) {
        Set-RepoSecret -OwnerRepo $ownerRepo -Name COPILOT_PAT -Token $CopilotToken
    }
    else {
        Write-Skip 'COPILOT_PAT not provided - release summaries stay manual'
    }

    # Sync still runs without this, but a PR opened with the default token cannot
    # trigger CI, so a required status check would never report and the PR would
    # never become mergeable.
    if ($TemplateSyncToken) {
        Set-RepoSecret -OwnerRepo $ownerRepo -Name TEMPLATE_SYNC_PAT `
            -Token $TemplateSyncToken
    }
    else {
        Write-Skip 'TEMPLATE_SYNC_PAT not provided - sync PRs will not run CI'
    }

    #───────────────────────────────────────────────────────────────────────────────
    # Step 3: clone + remotes
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '3' 'Clone the new repo'
    # Preserves the origin URL style, including any custom SSH host alias.
    $originUrl = Get-NewRepoUrl -SourceUrl $ctx.SourceUrl `
        -SourceOwnerRepo $ctx.SourceOwnerRepo `
        -NewOwnerRepo "$($ctx.SourceOwner)/$repo"
    Initialize-Clone -OriginUrl $originUrl `
        -TargetPath $targetPath `
        -TemplateUrl $ctx.SourceUrl

    #───────────────────────────────────────────────────────────────────────────────
    # Step 4: drop what belongs only to the parent
    #───────────────────────────────────────────────────────────────────────────────

    # Deletions run BEFORE the README pass,
    # so the README stops documenting files that have already gone,
    # rather than the other way round.
    Write-Step '4' 'Remove template-only files'
    $paths = @('.github', 'README.md', 'scripts')
    Invoke-GatedCommit -RepoPath $targetPath `
        -Message 'chore: remove template-only files' `
        -Paths $paths `
        -Body {
        Remove-TemplateOnlyFile -RepoPath $targetPath
        if ($Kind -eq 'Code') {
            # A leaf documents itself, not the chain it came from.
            Remove-ScriptsFolder -RepoPath $targetPath
            Reset-Readme -RepoPath $targetPath `
                -RepoName $repo `
                -Description $Description `
                -Visibility $Visibility
        }
        else {
            Update-Readme -RepoPath $targetPath
        }
    }

    #───────────────────────────────────────────────────────────────────────────────
    # Step 5: point this repo's docs at itself
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '5' 'Retarget template references'
    $paths = @(
        '.github/ISSUE_TEMPLATE'
        'CONTRIBUTING.md'
        'README.md'
        'SECURITY.md'
        'SUPPORT.md'
    )

    Invoke-GatedCommit -RepoPath $targetPath `
        -Message 'chore: retarget template references' `
        -Paths $paths `
        -Body {
        Update-RepoReference -RepoPath $targetPath `
            -OldOwnerRepo $ctx.SourceOwnerRepo `
            -NewOwnerRepo $ownerRepo
        Update-ReadmeDiagram -RepoPath $targetPath
        # A code repo's README is replaced wholesale in step 4, so retitling it
        # would only be undone.
        if ($Kind -ne 'Code') {
            Set-ReadmeTitle -RepoPath $targetPath -RepoName $repo
        }
    }

    #───────────────────────────────────────────────────────────────────────────────
    # Step 6: whatever THIS template layer needs (its optional layer module)
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '6' 'Apply template-specific customizations'
    # Carries the repo metadata as well as its identity, because a layer often has
    # somewhere of its own to put it - a NuGet layer writes the description and
    # topics into the package, for instance.
    Invoke-LayerModule -RepoPath $targetPath -Context @{
        RepoPath        = $targetPath
        RepoName        = $repo
        Kind            = $Kind
        OwnerRepo       = $ownerRepo
        SourceOwnerRepo = $ctx.SourceOwnerRepo
        Description     = $Description
        Homepage        = $Homepage
        Topics          = $Topics
        Visibility      = $Visibility
    }

    #───────────────────────────────────────────────────────────────────────────────
    # Step 7: this repo's own settings
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '7' 'Customize repo settings'
    $paths = @('.github/settings.yml', 'LICENSE')
    Invoke-GatedCommit -RepoPath $targetPath `
        -Message 'chore: customize repo settings' `
        -Paths $paths `
        -Body {
        Set-RepoLicense -RepoPath $targetPath -Visibility $Visibility
        # _extends resolves recursively, so this inherits the whole chain.
        Write-SettingsFile -RepoPath $targetPath `
            -Kind $Kind `
            -Name $repo `
            -ExtendsRepo $ctx.SourceRepo `
            -Description $Description `
            -Homepage $Homepage `
            -Topics $Topics `
            -Visibility $Visibility
    }

    #───────────────────────────────────────────────────────────────────────────────
    # Step 8: push (triggers Settings app) + CodeQL
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '8' 'Push & enable CodeQL'
    if (Push-Repo -RepoPath $targetPath) {
        Write-Detail "the 'Settings' app applies settings.yml in a few minutes"
    }

    Enable-Codeql -OwnerRepo $ownerRepo   # only now does the repo have content

    #───────────────────────────────────────────────────────────────────────────────
    # Step 9: initialize workflows, if anything changed
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '9' 'Initialize Template Sync'
    if ((Get-ChangeCount) -gt 0) {
        # A fresh repo is already a descendant of its template, so a clean run
        # finds nothing to sync. A pull request here means something is off.
        $sync = Start-TemplateSync -OwnerRepo $ownerRepo
        Wait-TemplateSync -OwnerRepo $ownerRepo -Handle $sync
    }
    else {
        Write-Skip 'Nothing changed this run - Template Sync is already initialized'
    }

    #───────────────────────────────────────────────────────────────────────────────
    # Step 10: VS Code multi-root workspace, then open it
    #───────────────────────────────────────────────────────────────────────────────

    Write-Step '10' 'Set up the VS Code workspace'
    # The workspace file is already ignored by the inherited .gitignore,
    # so it never reaches a commit and never syncs to a descendant.

    # The chain is the source template plus every ancestor cloned locally,
    # nearest first.
    $chain = Get-TemplateChain -StartRepoPath $ctx.SourceRoot `
        -ParentDir $ctx.ParentDir
    $wsFile = Write-WorkspaceFile -RepoPath $targetPath `
        -RepoName $repo `
        -ChainPaths $chain

    # Queued before the file is written, so it can be opened as the active
    # tab alongside the workspace, rather than only printed after VS Code is
    # already up. Console output at the very end is unaffected - it just
    # reads the same queue back.
    Register-ManualGitHubSetting -OwnerRepo $ownerRepo -Visibility $Visibility
    if ($Kind -eq 'Code') {
        Register-ManualCiWorkflow -RepoPath $targetPath
    }
    $checklistFile = Write-ManualChecklistFile -RepoPath $targetPath

    Start-VSCode -Target $wsFile -ActiveFile $checklistFile
}
finally {
    # Runs on every way out of the try above - success, a thrown error, the
    # early return in Step 0, or Ctrl-C, which stops the pipeline without
    # ever invoking the trap but still runs a pending finally.
    #
    # Each cleanup step is guarded on its own. A failure here must not
    # replace a real error already propagating out of the try - that would
    # swap a genuine failure for a misdiagnosis about cleanup instead.
    foreach ($step in 'Remove-LayerModule', 'Reset-GhAccount') {
        try { & $step }
        catch {
            Write-Warn "cleanup step $step failed: $($_.Exception.Message)"
        }
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Manual follow-up checklist
#───────────────────────────────────────────────────────────────────────────────

# Every step has finished, so nothing below belongs to one. Without this, a
# failure here would name the last step, which had already succeeded.
Clear-Step

Show-ManualChecklist -OwnerRepo $ownerRepo
Show-Summary

if ((Get-ChangeCount) -eq 0) {
    Write-Host "  ✅ $ownerRepo was already fully scaffolded." `
        -ForegroundColor Green
}
else {
    $kindLabel = $Kind.ToLowerInvariant()
    Write-Host "  🎉 $kindLabel repo $ownerRepo ready at $targetPath." `
        -ForegroundColor Green
}

Write-Host ""
