#Requires -Version 7.0
<#
    Getting a value from the caller, wherever it came from.

    One set of rules for a value passed on the command line, one typed at a
    prompt, and one that fell through to a default - because a value is only
    trustworthy if it was checked the same way regardless of how it arrived.

    Every prompt here honours a single suppression switch, so an unattended
    run cannot block on one that was forgotten.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force here. Import-Module -Force removes the module first, which would
# also tear it out of the calling script's scope - so the entry script owns
# -Force and a nested import is a no-op once it is already loaded.
Import-Module (Join-Path $PSScriptRoot 'Common-Console.psm1')

#───────────────────────────────────────────────────────────────────────────────
# Prompt suppression
#───────────────────────────────────────────────────────────────────────────────

# Suppresses every prompt, for an unattended run.
$script:SkipManualPrompts = $false

function Set-SkipPrompt {
    <#
    .SYNOPSIS
        Suppresses every prompt, for an unattended run.
    #>
    param([Parameter(Mandatory)][bool]$Skip)
    $script:SkipManualPrompts = $Skip
}

function Test-SkipPrompt {
    <#
    .SYNOPSIS
        Reports whether prompts are currently suppressed.
    .DESCRIPTION
        For a caller that has to skip an interactive step of its own, rather
        than keeping a second copy of the switch.
    #>
    return $script:SkipManualPrompts
}

#───────────────────────────────────────────────────────────────────────────────
# Formats
#───────────────────────────────────────────────────────────────────────────────

# One regex for a repo-name slug, so Format-Slug and every prompt that
# validates one cannot drift apart.
$script:SlugPattern = '^[a-z0-9]+(-[a-z0-9]+)*$'

function Get-SlugPattern {
    <#
    .SYNOPSIS
        Returns the regex a repo-name slug must match.
    #>
    return $script:SlugPattern
}

function Format-Slug {
    <#
    .SYNOPSIS
        Normalises and validates a repo-name slug:
        one regex and one error wording for the whole chain.
    #>
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    $slug = $Value.Trim().ToLowerInvariant()
    if ($slug -notmatch $script:SlugPattern) {
        throw "$Label must be kebab-case (letters/digits/hyphens): '$slug'"
    }

    return $slug
}

function Format-TopicList {
    <#
    .SYNOPSIS
        Normalises a comma-separated topic list into what GitHub accepts.
    .DESCRIPTION
        GitHub topics are lowercase, may hold only letters, digits and
        hyphens, must start with a letter or digit, and cap at 50 characters.
        An invalid one makes the Settings app drop the whole list without
        saying so, so this trims, lowercases, de-duplicates, and rejects
        anything still malformed.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    $topics = @($Value -split ',' |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ })
    $topics = @($topics | Select-Object -Unique)

    foreach ($topic in $topics) {
        if ($topic.Length -gt 50) {
            throw "$Label - '$topic' is over 50 characters"
        }
        if ($topic -notmatch '^[a-z0-9][a-z0-9-]*$') {
            throw ("$Label - '$topic' must be lowercase letters, digits " +
                'and hyphens, starting with a letter or digit')
        }
    }

    return ($topics -join ', ')
}

#───────────────────────────────────────────────────────────────────────────────
# Validation
#───────────────────────────────────────────────────────────────────────────────

function Get-InputError {
    <#
    .SYNOPSIS
        Returns why a value is unacceptable, or $null when it is fine.
    .DESCRIPTION
        Split out from Resolve-Input so the same rules apply to a value
        supplied on the command line, a prompted one, and a default.
    .PARAMETER Requirement
        Plain-English version of -Pattern, used in the message. Regexes
        make poor error messages.
    #>
    param(
        [AllowEmptyString()][string]$Value,
        [string[]]$Choice,
        [string]$Pattern,
        [string]$Requirement,
        [bool]$Require
    )
    if (-not $Value) {
        if ($Require) { return 'is required' }
        return $null
    }
    if ($Choice -and $Value -notin $Choice) {
        return "must be one of: $($Choice -join ', ')"
    }
    if ($Pattern -and $Value -notmatch $Pattern) {
        if ($Requirement) { return $Requirement }
        return "must match $Pattern"
    }
    return $null
}

function Resolve-Input {
    <#
    .SYNOPSIS
        Returns a validated value from the command line, a prompt, or a default.
    .DESCRIPTION
        - If the caller passed the parameter
          (tracked in $Bound = $PSBoundParameters),
          uses $Value as-is and does NOT prompt,
          even if it is an empty string.
        - Otherwise, if prompts are suppressed (Set-SkipPrompt $true),
          returns $Default without prompting, so unattended runs never block.
        - Otherwise prompts. A non-empty -Default is shown as [default],
          and ENTER accepts it. -Secret prompts without echo, for tokens.

        Validation applies to all three, but the response differs: an
        interactive prompt says what is wrong and asks again, while a bad
        command-line value or default throws, because there is nobody to ask.
        Everything except a secret is trimmed, and a -Choice match is
        returned in the casing the choice list declares.
    .PARAMETER Choice
        Accept only these values, case-insensitively.
    .PARAMETER Pattern
        Regex the value must match when it is not empty.
    .PARAMETER Requirement
        Plain-English version of -Pattern, for the error message.
    .PARAMETER Require
        Reject an empty value. Without it, empty is allowed and skips the
        other checks - which is what an optional setting like a homepage
        wants.
    .PARAMETER EnvVar
        Environment variable to fall back on before prompting, so a value
        set once on the machine is never asked for again. The command line
        still wins, and an empty variable counts as unset.
    .PARAMETER Hint
        Lines shown immediately before prompting, and only then - there is
        nothing to explain when the value already came from somewhere.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Bound,
        $Value,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [string[]]$Choice,
        [string]$Pattern,
        [string]$Requirement,
        [switch]$Require,
        [switch]$Secret,
        [string]$EnvVar,
        [string[]]$Hint
    )

    $fromEnv = if ($EnvVar) { [Environment]::GetEnvironmentVariable($EnvVar) } else { $null }

    # Announced, because a value arriving from the environment is invisible
    # otherwise, and a stale variable is hard to spot when nothing says so.
    $announce = {
        Write-Ok "$EnvVar found in the environment"
    }

    $showHint = {
        foreach ($line in $Hint) { Write-Detail $line }
        if ($EnvVar) {
            Write-Detail "Set the $EnvVar environment variable to skip this prompt"
        }
    }
    $rules = @{
        Choice      = $Choice
        Pattern     = $Pattern
        Requirement = $Requirement
        Require     = $Require.IsPresent
    }

    # Canonical casing, so -Visibility private yields 'Private'.
    $canonical = {
        param($Result)
        if ($Choice -and $Result) {
            $match = @($Choice | Where-Object { $_ -eq $Result })
            if ($match) { return $match[0] }
        }
        return $Result
    }

    if ($Secret) {
        if ($Bound.ContainsKey($Name)) { return [string]$Value }
        if ($fromEnv) { & $announce; return $fromEnv }
        if ($script:SkipManualPrompts) { return $Default }
        & $showHint
        $sec = Read-Host -AsSecureString $Prompt
        return [System.Net.NetworkCredential]::new('', $sec).Password
    }

    # The command line outranks the environment, so an explicit argument is
    # never quietly overridden by a variable set months ago.
    if ($Bound.ContainsKey($Name)) {
        $result = ([string]$Value).Trim()
        $err = Get-InputError -Value $result @rules
        if ($err) { throw "-$Name $err (got '$result')" }
        return (& $canonical $result)
    }

    if ($fromEnv) {
        & $announce
        $result = $fromEnv.Trim()
        $err = Get-InputError -Value $result @rules
        if ($err) { throw "`$env:$EnvVar $err (got '$result')" }
        return (& $canonical $result)
    }

    if ($script:SkipManualPrompts) {
        $result = $Default.Trim()
        $err = Get-InputError -Value $result @rules
        if ($err) { throw "-$Name was not supplied, and its default $err" }
        return (& $canonical $result)
    }

    & $showHint
    $label = $Prompt
    if ($Choice) { $label += " ($($Choice -join '/'))" }
    if ($Default -ne '') { $label += " [$Default]" }

    while ($true) {
        $entered = Read-Host $label
        $result = if ([string]::IsNullOrEmpty($entered)) { $Default }
        else { $entered }
        $result = $result.Trim()

        $err = Get-InputError -Value $result @rules
        if (-not $err) { return (& $canonical $result) }
        Write-Warn "$Name $err"
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Confirmation
#───────────────────────────────────────────────────────────────────────────────

function Confirm-Proceed {
    <#
    .SYNOPSIS
        Returns $true when the run should continue - the final go/no-go gate.
    .DESCRIPTION
        Honours this module's own skip-prompts state, rather than a second
        copy of the switch in each script, and reports an abort through
        Write-Warn so it looks like every other warning.

        Requires the word 'yes' rather than accepting anything truthy:
        a gate that a stray keypress can pass is not a gate.
    .PARAMETER Action
        What is about to happen, completing "Type 'yes' to ...".
    #>
    param([Parameter(Mandatory)][string]$Action)

    if ($script:SkipManualPrompts) { return $true }
    if ((Read-Host "  Type 'yes' to $Action") -eq 'yes') { return $true }

    Write-Warn 'Aborted by user.'
    return $false
}

Export-ModuleMember -Function @(
    'Set-SkipPrompt'
    'Test-SkipPrompt'
    'Get-SlugPattern'
    'Format-Slug'
    'Format-TopicList'
    'Get-InputError'
    'Resolve-Input'
    'Confirm-Proceed'
)
