#Requires -Version 7.0
<#
    Getting a value from the caller, wherever it came from.

    One set of rules for a value taken from the environment and one typed at
    a prompt - because a value is only trustworthy if it was checked the same
    way regardless of how it arrived. A secret is the deliberate exception:
    there is nothing worth checking in an opaque token.

    Only a prompt can be told it is wrong and asked again. An environment
    variable has nobody to ask, so it throws instead, naming where the value
    came from.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Prompts
#───────────────────────────────────────────────────────────────────────────────

# A prompt that cannot be answered has to end the run rather than spin.
# Read-Host returns $null the instant standard input is at its end, so a script
# whose input is redirected would otherwise re-offer the same rejected value
# forever, printing a warning each time.
$script:MaxPromptAttempts = 10

#───────────────────────────────────────────────────────────────────────────────
# Formats
#───────────────────────────────────────────────────────────────────────────────

# One regex for a repo-name slug, and one wording of the same rule, so
# Format-Slug and every prompt that validates one cannot drift apart. A single
# leading dot is allowed, because that is how the infrastructure repos are
# marked as not being projects - the convention '.github' and '.template-*'
# already follow.
$script:SlugPattern = '^\.?[a-z0-9]+(-[a-z0-9]+)*$'
$script:SlugRequirement = 'must be kebab-case: lowercase letters, digits and ' +
'hyphens, with an optional leading dot'

# GitHub's rules for a repo topic. The count is the one that bites: the
# Settings app applies topics asynchronously from settings.yml, so a list it
# rejects is dropped whole and no HTTP error reaches the run.
$script:TopicPattern = '^[a-z0-9][a-z0-9-]*$'
$script:MaxTopicLength = 50
$script:MaxTopicCount = 20

function Get-SlugPattern {
    <#
    .SYNOPSIS
        Returns the regex a repo-name slug must match.
    #>
    return $script:SlugPattern
}

function Get-SlugRequirement {
    <#
    .SYNOPSIS
        Returns the slug rule in plain English, for a prompt or an error.
    #>
    return $script:SlugRequirement
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
        throw "$Label $script:SlugRequirement (got '$slug')"
    }

    return $slug
}

function Split-TopicList {
    <#
    .SYNOPSIS
        Splits a comma-separated topic list into normalised, unique topics.
    .DESCRIPTION
        Not exported. Trims, lowercases, drops empty entries and
        de-duplicates - the shared front half of validating a list and
        formatting one, so the two cannot disagree about what the topics are.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $topics = @($Value -split ',' |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ })

    # Order is the caller's, not sorted: they chose it, and GitHub keeps it.
    # No leading comma: Get-TopicListError, the only caller, already wraps
    # this call in its own @() - which is what actually guards against a
    # one-item result unrolling to a scalar. Adding one here too would instead
    # double-wrap every OTHER count, nesting the real array inside another.
    return @($topics | Select-Object -Unique)
}

function Format-Quoted {
    <#
    .SYNOPSIS
        Renders values as a quoted, comma-separated list for a message.
    .DESCRIPTION
        Not exported.
    #>
    param([Parameter(Mandatory)][string[]]$Value)
    return (($Value | ForEach-Object { "'$_'" }) -join ', ')
}

function Get-TopicListError {
    <#
    .SYNOPSIS
        Returns why a comma-separated topic list is unacceptable,
        or $null when it is fine.
    .DESCRIPTION
        Names every offending topic rather than the first, so one correction
        settles the whole list. Pass this to Resolve-Input -Validate, so a
        typed list can be corrected instead of ending the run.

        Worded as a clause completing "<what> ...", like every other reason
        Get-InputError returns, so the caller supplies the name.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $topics = @(Split-TopicList -Value $Value)
    if ($topics.Count -gt $script:MaxTopicCount) {
        return ("lists $($topics.Count) topics, but GitHub keeps at most " +
            "$script:MaxTopicCount")
    }

    # Character check before length, so a topic that breaks both is told about
    # the character it cannot have rather than only its size.
    $malformed = @($topics | Where-Object { $_ -notmatch $script:TopicPattern })
    if ($malformed) {
        return ('must be lowercase letters, digits and hyphens, starting ' +
            "with a letter or digit: $(Format-Quoted $malformed)")
    }

    $oversized = @($topics |
        Where-Object { $_.Length -gt $script:MaxTopicLength })
    if ($oversized) {
        return ("must be $script:MaxTopicLength characters or fewer: " +
            (Format-Quoted $oversized))
    }

    return $null
}

function Format-TopicList {
    <#
    .SYNOPSIS
        Normalises and validates a comma-separated topic list into what GitHub
        accepts.
    .DESCRIPTION
        Trims, lowercases, de-duplicates and drops empty entries, then throws
        if anything is still wrong.

        An empty list is allowed: a repo with no topics is a repo with no
        topics. Anything else invalid has to stop the run, because GitHub
        silently drops a list it does not like - see Get-TopicListError, which
        a prompt should use instead so a typo can be corrected.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Label
    )

    $reason = Get-TopicListError -Value $Value
    if ($reason) { throw "$Label $reason" }

    return ((Split-TopicList -Value $Value) -join ', ')
}

#───────────────────────────────────────────────────────────────────────────────
# Validation
#───────────────────────────────────────────────────────────────────────────────

function Get-InputError {
    <#
    .SYNOPSIS
        Returns why a value is unacceptable, or $null when it is fine.
    .DESCRIPTION
        Split out from Resolve-Input so the same rules apply to a value read
        from the environment and one typed at a prompt. Not exported: callers
        reach these rules through Resolve-Input.
    .PARAMETER Requirement
        Plain-English version of -Pattern, used in the message. Regexes
        make poor error messages.
    .PARAMETER Validate
        Checked last, and only for a non-empty value, so a caller's own rule
        never has to re-handle empty or restate the basics.
    #>
    param(
        [AllowEmptyString()][string]$Value,
        [string[]]$Choice,
        [string]$Pattern,
        [string]$Requirement,
        [scriptblock]$Validate,
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

    if ($Validate) {
        $reason = & $Validate $Value
        if ($reason) { return [string]$reason }
    }

    return $null
}

function Assert-InputValid {
    <#
    .SYNOPSIS
        Throws when a value breaks its rules, naming where the value came from.
    .DESCRIPTION
        Not exported. A value read from the environment has nobody to ask for
        a correction, so it can only throw - and the message has to say that
        is where it came from, or the reader cannot tell what to go and change.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][hashtable]$Rules,
        [Parameter(Mandatory)][string]$Source,
        [switch]$ShowValue
    )

    $err = Get-InputError -Value $Value @Rules
    if (-not $err) { return }

    $message = "$Source $err"
    if ($ShowValue) { $message += " (got '$Value')" }
    throw $message
}

#───────────────────────────────────────────────────────────────────────────────
# Resolution
#───────────────────────────────────────────────────────────────────────────────

function Get-CanonicalChoice {
    <#
    .SYNOPSIS
        Returns a -Choice match in the casing the choice list declares.
    .DESCRIPTION
        Not exported. So an environment variable holding 'private' yields
        'Private', and every comparison after this point can be a plain
        string match.
    #>
    param(
        [AllowEmptyString()][string]$Value,
        [string[]]$Choice
    )

    if (-not $Choice -or -not $Value) { return $Value }

    $match = @($Choice | Where-Object { $_ -eq $Value })
    if ($match) { return $match[0] }
    return $Value
}

function Resolve-KnownValue {
    <#
    .SYNOPSIS
        Trims, validates and canonicalises a value that did not come from a
        prompt, and returns it ready to use.
    .DESCRIPTION
        Not exported. Kept apart from the prompt path because an environment
        variable that fails validation throws rather than being corrected.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][hashtable]$Rules,
        [Parameter(Mandatory)][string]$Source,
        [switch]$ShowValue
    )

    $trimmed = $Value.Trim()
    Assert-InputValid -Value $trimmed -Rules $Rules -Source $Source `
        -ShowValue:$ShowValue
    return (Get-CanonicalChoice -Value $trimmed -Choice $Rules.Choice)
}

function Show-InputHint {
    <#
    .SYNOPSIS
        Prints the lines shown immediately before a prompt.
    .DESCRIPTION
        Not exported. Only reached when a prompt is actually about to happen:
        there is nothing to explain when the value already came from the
        environment.
    #>
    param(
        [string[]]$Hint,
        [string]$EnvVar
    )

    foreach ($line in $Hint) { Write-Detail $line }
    if ($EnvVar) {
        Write-Detail "Set the $EnvVar environment variable to skip this prompt"
    }
}

function Read-SecretValue {
    <#
    .SYNOPSIS
        Reads a value without echoing it.
    .DESCRIPTION
        Not exported. Returned untrimmed and unvalidated: a token is opaque,
        so there are no rules worth applying to it.
    #>
    param([Parameter(Mandatory)][string]$Prompt)

    $secure = Read-Host -AsSecureString $Prompt
    return [System.Net.NetworkCredential]::new('', $secure).Password
}

function Read-PromptedValue {
    <#
    .SYNOPSIS
        Prompts until the answer passes its rules, then returns it.
    .DESCRIPTION
        Not exported. An interactive answer is the one source that can be
        corrected, so a bad one says what is wrong and asks again instead of
        throwing - up to a bounded number of attempts.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [AllowEmptyString()][string]$Default = '',
        [string[]]$Choice,
        [Parameter(Mandatory)][hashtable]$Rules
    )

    $label = $Prompt
    if ($Choice) { $label += " ($($Choice -join '/'))" }
    if ($Default -ne '') { $label += " [$Default]" }

    for ($attempt = 1; $attempt -le $script:MaxPromptAttempts; $attempt++) {
        $entered = Read-Host $label
        # Emptiness is judged after trimming, so a stray space still means
        # 'accept the default' rather than 'answer with nothing'.
        $value = if ([string]::IsNullOrWhiteSpace($entered)) { $Default }
        else { $entered.Trim() }

        $err = Get-InputError -Value $value @Rules
        if (-not $err) {
            return (Get-CanonicalChoice -Value $value -Choice $Choice)
        }

        Write-Warn "$Name $err"
    }

    throw ("$Name was not answered acceptably in " +
        "$script:MaxPromptAttempts attempts")
}

function Resolve-Input {
    <#
    .SYNOPSIS
        Returns a validated value from the environment or a prompt,
        preferring the environment.
    .DESCRIPTION
        The precedence is the whole point: a value set once on the machine is
        never asked for again, but nothing here can run unattended - every
        path that is not the environment ends at a prompt, so a script that
        forgets to answer something is stopped by that prompt, not by a
        silently-accepted default.

        - Set in -EnvVar? Use that, and say so.
        - Otherwise prompt, showing a non-empty -Default as [default].

        Both are trimmed, validated, and re-cased to match -Choice. Only a
        prompt can be corrected; an environment variable throws, because there
        is nobody to ask. -Secret opts out of all of it.
    .PARAMETER Name
        The caller's own parameter name. Used on the label on a prompt warning,
        so it has to match the declaration, not read nicely.
    .PARAMETER Default
        Offered as [default] at a prompt - press enter to accept it. Not
        validated up front: a bad default just fails like any other answer and
        prompts again.
    .PARAMETER Choice
        Accept only these values, case-insensitively. The value comes back in
        the casing declared here, so later comparisons can be plain matches.
    .PARAMETER Pattern
        Regex the value must match when it is not empty.
    .PARAMETER Requirement
        Plain-English version of -Pattern, for the error message.
    .PARAMETER Validate
        A rule too specific for a regex. Takes the value, returns why it is
        unacceptable or $null. Checked last, and only when the value is not
        empty.
    .PARAMETER Require
        Reject an empty value. Without it, empty is allowed and skips the
        other checks - which is what an optional setting like a homepage
        wants.
    .PARAMETER Secret
        Read without echo, and skip trimming, validation and canonicalisation
        on every path. Excludes the checking parameters, so a rule that would
        be ignored cannot be passed in the first place.
    .PARAMETER EnvVar
        Environment variable to check before prompting, so a value set once on
        the machine is never asked for again. A variable that is empty or
        holds only whitespace counts as unset.
    .PARAMETER Hint
        Lines shown immediately before prompting, and only then.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Checked')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [string]$EnvVar,
        [string[]]$Hint,
        [Parameter(ParameterSetName = 'Checked')][string[]]$Choice,
        [Parameter(ParameterSetName = 'Checked')][string]$Pattern,
        [Parameter(ParameterSetName = 'Checked')][string]$Requirement,
        [Parameter(ParameterSetName = 'Checked')][scriptblock]$Validate,
        [Parameter(ParameterSetName = 'Checked')][switch]$Require,
        [Parameter(Mandatory, ParameterSetName = 'Secret')][switch]$Secret
    )

    # -Requirement exists to reword a -Pattern failure; without one it is
    # never read, so a caller who passes it alone would see it silently do
    # nothing instead of the message they meant to write.
    if ($Requirement -and -not $Pattern) {
        throw '-Requirement has no effect without -Pattern'
    }

    # Trimmed here so that a variable holding only whitespace counts as unset
    # everywhere, including the secret path - which returns before any other
    # trimming and would otherwise hand back spaces as the value.
    $fromEnv = if ($EnvVar) {
        [Environment]::GetEnvironmentVariable($EnvVar)
    }
    else { $null }
    if ($fromEnv) { $fromEnv = $fromEnv.Trim() }

    # Announced because a value arriving from the environment is invisible
    # otherwise, and a stale variable is hard to spot when nothing says where
    # the value came from.
    if ($fromEnv) { Write-Ok "$EnvVar found in the environment" }

    if ($PSCmdlet.ParameterSetName -eq 'Secret') {
        if ($fromEnv) { return $fromEnv }
        Show-InputHint -Hint $Hint -EnvVar $EnvVar
        return (Read-SecretValue -Prompt $Prompt)
    }

    $rules = @{
        Choice      = $Choice
        Pattern     = $Pattern
        Requirement = $Requirement
        Validate    = $Validate
        Require     = $Require.IsPresent
    }

    if ($fromEnv) {
        return (Resolve-KnownValue -Value $fromEnv -Rules $rules `
                -Source "`$env:$EnvVar" -ShowValue)
    }

    Show-InputHint -Hint $Hint -EnvVar $EnvVar
    return (Read-PromptedValue -Name $Name -Prompt $Prompt -Default $Default `
            -Choice $Choice -Rules $rules)
}

#───────────────────────────────────────────────────────────────────────────────
# Confirmation
#───────────────────────────────────────────────────────────────────────────────

function Confirm-Proceed {
    <#
    .SYNOPSIS
        Returns $true when the run should continue - the final go/no-go gate.
    .DESCRIPTION
        Reports an abort through Write-Warn, so it looks like every other
        warning.

        Requires the word 'yes', in any casing, rather than accepting anything
        truthy: a gate that a stray keypress can pass is not a gate.
    .PARAMETER Action
        What is about to happen, completing "Type 'yes' to ...".
    #>
    param([Parameter(Mandatory)][string]$Action)

    if ((Read-Host "  Type 'yes' to $Action") -eq 'yes') { return $true }

    Write-Warn 'Aborted by user'
    return $false
}

Export-ModuleMember -Function @(
    'Get-SlugPattern'
    'Get-SlugRequirement'
    'Format-Slug'
    'Get-TopicListError'
    'Format-TopicList'
    'Resolve-Input'
    'Confirm-Proceed'
)
