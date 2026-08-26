#Requires -Version 7.0
<#
    Discovering, loading, and running a script's own layer modules - the
    New-Repo-<NN>-<slug>.psm1 files a template layer drops in beside it to
    extend the base scaffolding, without editing the base at all.

    A layer contributes an entry point by NAME, not by registration: any
    exported function matching Invoke-*Scaffold is it. The tier number in
    the filename is what fixes the order entry points RUN in - load order
    does not matter, since every module is loaded -Global before any of
    them is called.

    Inherited by merge, so keep it identical at every layer:
    a per-layer edit conflicts on every future template change.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Discovery
#───────────────────────────────────────────────────────────────────────────────

# A layer module is named New-Repo-<NN>-<slug>.psm1. The tier number is what
# makes it a layer rather than just a module: this folder also holds shared
# modules and other scripts' modules, and loading one of those as a layer
# would be wrong. Requiring the digits keeps the two apart by name alone.
#
# Exactly two digits, because the tier is what orders the layers and it is
# compared as a number - '9' after '10', not before '100' as a string sort
# would have it. Anything digit-led that is not two digits is refused rather
# than ignored: a file that LOOKS like a layer must not silently be neither.
#
# New-Repo.ps1 excludes every digit-led New-Repo-*.psm1 when it loads its OWN
# modules, so a layer is never double-loaded. Keep the two in step.
$script:LayerModulePrefix = '^New-Repo-\d+-'
$script:LayerModulePattern = '^New-Repo-(?<tier>\d{2})-.+\.psm1$'

# What every layer may rely on finding in -Context. Checked once, before any
# layer runs: under StrictMode a missing key would otherwise throw deep inside
# whichever layer reads it first, blaming the layer for the caller's omission.
$script:ContextKeys = @(
    'RepoPath', 'RepoName', 'Kind', 'OwnerRepo', 'SourceOwnerRepo'
    'Description', 'Homepage', 'Topics', 'Visibility'
)

function Get-LayerModule {
    <#
    .SYNOPSIS
        Finds every layer module alongside this one, in load order.
    .DESCRIPTION
        Not exported. A layer adds one by dropping it in - nothing inherited
        gets edited.

        Sorted by tier number, compared as a number rather than as text.
        Import order is not what matters (every module is -Global, and calls
        happen later); the tier fixes the order their entry points RUN in, so
        a parent's scaffolding finishes before a child's starts.
    #>
    $files = Get-ChildItem -Path $PSScriptRoot `
        -Filter '*.psm1' `
        -File `
        -ErrorAction SilentlyContinue

    $layers = foreach ($file in $files) {
        if ($file.Name -notmatch $script:LayerModulePrefix) { continue }
        $match = [regex]::Match($file.Name, $script:LayerModulePattern, 'IgnoreCase')
        if (-not $match.Success) {
            throw ("$($file.Name) looks like a layer module, but the tier must " +
                'be exactly two digits: New-Repo-<NN>-<slug>.psm1')
        }

        [pscustomobject]@{ Tier = [int]$match.Groups['tier'].Value; File = $file }
    }

    $shared = @($layers | Group-Object Tier | Where-Object { $_.Count -gt 1 })
    if ($shared) {
        $names = @($shared | ForEach-Object { $_.Group.File.Name }) -join ', '
        throw "Two layer modules share a tier, so their order is ambiguous: $names"
    }

    return @($layers | Sort-Object Tier | ForEach-Object { $_.File })
}

function Import-LayerModule {
    <#
    .SYNOPSIS
        Loads every layer module and returns those that contribute an entry point.
    .DESCRIPTION
        Not exported. Imported -Global, so each layer's exported helpers are
        visible to the layers below it.

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
    # What is LOADED, not what is on disk: this runs from the entry script's
    # cleanup, where a malformed layer file must not throw a second time.
    $loaded = @(Get-Module | Where-Object { $_.Name -match $script:LayerModulePrefix })
    foreach ($module in $loaded) {
        Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Running
#───────────────────────────────────────────────────────────────────────────────

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
        The repo's identity - RepoPath, RepoName, Kind, OwnerRepo,
        SourceOwnerRepo - and its metadata: Description, Homepage, Topics,
        Visibility. The metadata is there because a layer often has somewhere
        of its own to put it. Every key is required, even with an empty value.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][hashtable]$Context
    )

    $missing = @($script:ContextKeys | Where-Object { -not $Context.ContainsKey($_) })
    if ($missing) {
        throw "-Context is missing $($missing -join ', ')"
    }

    $layers = Import-LayerModule
    if (-not $layers) {
        Write-Skip ('No New-Repo-<NN>-<slug>.psm1 layers in this chain - ' +
            'nothing template-specific to apply')
        return
    }

    # Snapshot first, so the check below reports only what the LAYERS dirtied.
    # The developer's own uncommitted work was already there, and is none of
    # our business. Through Invoke-Git, so a status that FAILS is not read as
    # a clean tree - which would blame the layers for everything already dirty.
    #
    # Not wrapped in @(): Invoke-Git already returns an array, and wrapping it
    # again would nest it - every path would then read as newly dirty.
    $status = {
        Invoke-Git -Activity 'Reading the working tree' -RepoPath $RepoPath `
            -Arguments @('status', '--porcelain')
    }

    $before = & $status
    if ($before) {
        Write-Info "$($before.Count) path(s) were already modified - the layers leave them alone"
    }

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
        foreach ($line in $left) { Write-Detail $line.Trim() }
        Write-Detail 'a layer should commit via Invoke-GatedCommit'
    }
}

Export-ModuleMember -Function @(
    'Invoke-LayerModule'
    'Remove-LayerModule'
)
