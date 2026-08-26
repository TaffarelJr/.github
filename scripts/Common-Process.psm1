#Requires -Version 7.0
<#
    Running an external command and noticing when it fails.

    A native command exiting non-zero does NOT stop PowerShell, whatever
    $ErrorActionPreference says. So every external call has to be checked
    explicitly, or a failure is silently reported as success - which is the
    single easiest way for a script here to lie about what it did.

    These wrappers capture the command's own output rather than letting it
    scribble over the log, and fold it into the error when something breaks,
    so a failure says what went wrong instead of just that it did.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force here. Import-Module -Force removes the module first, which would
# also tear it out of the calling script's scope - so the entry script owns
# -Force and a nested import is a no-op once it is already loaded.
Import-Module (Join-Path $PSScriptRoot 'Common-Console.psm1')

#───────────────────────────────────────────────────────────────────────────────
# Exit codes
#───────────────────────────────────────────────────────────────────────────────

function Assert-LastExit {
    <#
    .SYNOPSIS
        Throws if the last native command exited non-zero.
    .DESCRIPTION
        For a call whose output is wanted on the console as it happens, so it
        cannot be wrapped. Use Invoke-Git or Invoke-Gh instead when the output
        is only interesting if the command fails.
    #>
    param([Parameter(Mandatory)][string]$What)

    if ($LASTEXITCODE -ne 0) {
        throw "$What failed (exit code $LASTEXITCODE)"
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Wrappers
#───────────────────────────────────────────────────────────────────────────────

function Invoke-Git {
    <#
    .SYNOPSIS
        Runs git with its chatter captured rather than dumped to the console.
    .DESCRIPTION
        Turns a non-zero exit into a clean error,
        with git's own output included as detail.

        Only for calls where failure is genuinely an error.
        Calls that USE the exit code as a boolean stay raw -
        show-ref --quiet, diff --cached --quiet, rev-parse --verify.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    # -Arguments must be an explicit array: loose tokens like '-C' bind as
    # PowerShell parameters instead of git arguments, without any error.
    $argv = if ($RepoPath) {
        @('-C', $RepoPath) + $Arguments
    }
    else { $Arguments }
    $out = & git @argv 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        throw ("$What failed: git $($argv -join ' ') (exit $LASTEXITCODE)" +
            $(if ($detail) { "`n$detail" } else { '' }))
    }
    return $out
}

function Invoke-Gh {
    <#
    .SYNOPSIS
        Runs gh exactly as Invoke-Git runs git.
        -Arguments must be an explicit array.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $out = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        throw ("$What failed: gh $($Arguments -join ' ') (exit $LASTEXITCODE)" +
            $(if ($detail) { "`n$detail" } else { '' }))
    }
    return $out
}

Export-ModuleMember -Function @(
    'Assert-LastExit'
    'Invoke-Git'
    'Invoke-Gh'
)
