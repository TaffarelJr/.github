#Requires -Version 7.0
<#
    Locating this repo in its template chain - the source template it was
    derived from, every ancestor cloned locally, and the URL a sibling repo
    would have.

    Inherited by merge, so keep it identical at every layer:
    a per-layer edit conflicts on every future template change.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

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

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found on PATH."
    }

    $originUrl = Get-RemoteUrl -RepoPath $sourceRoot -Name 'origin'
    if (-not $originUrl) {
        throw "Could not read 'origin' remote from '$sourceRoot'."
    }

    if ($originUrl -notmatch '[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') {
        throw "Could not parse owner/repo from origin URL '$originUrl'."
    }

    if ($Matches['owner'] -ne (Get-RepoOwner)) {
        Write-Warn ("This repo's origin owner is '$($Matches['owner'])' " +
            "but the configured owner is '$(Get-RepoOwner)'. " +
            "Update `$script:RepoOwner in Common-GitHub.psm1 if that's wrong.")
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
        Walking stops when a repo has no 'template' remote (the base), when
        its URL cannot be parsed, or when the next ancestor isn't cloned
        locally. Cycles and runaway depth are guarded.
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
        # A missing 'template' remote means the base layer was reached.
        $url = Get-RemoteUrl -RepoPath $cur -Name 'template'
        if (-not $url) { break }
        if ($url -notmatch '[:/][^/]+/([^/]+?)(\.git)?$') {
            Write-Warn "Could not parse the 'template' remote of '$cur' - ending chain walk"
            break
        }

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

    return $chain.ToArray()
}

function Get-NewRepoUrl {
    <#
    .SYNOPSIS
        Builds the git URL for a sibling repo,
        by swapping the owner/repo path in the source URL.
    .DESCRIPTION
        Preserves the host and protocol,
        including a custom SSH alias like git@github.com-personal:...,
        so the new repo's origin uses the same credentials.
    .PARAMETER SourceOwnerRepo
        The 'owner/repo' to swap OUT. The new repo keeps the source's owner
        even when it differs from the configured one - Get-TemplateContext has
        already warned about that, and the URL must stay reachable.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$SourceOwnerRepo,
        [Parameter(Mandatory)][string]$NewOwnerRepo
    )

    # Ordinal replace, not -replace: a URL is not a regex, and the replacement
    # string's '$' would be a substitution rather than a character.
    $url = $SourceUrl.Replace($SourceOwnerRepo, $NewOwnerRepo)
    if ($url -eq $SourceUrl) {
        throw "Could not derive sibling URL from '$SourceUrl'."
    }

    return $url
}

Export-ModuleMember -Function @(
    'Get-TemplateContext'
    'Get-TemplateChain'
    'Get-NewRepoUrl'
)
