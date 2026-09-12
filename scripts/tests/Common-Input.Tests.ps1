#Requires -Version 7.0
<#
    Tests for Common-Input.psm1: Resolve-Input's environment-then-prompt
    resolution and its validation rules, the topic and slug helpers, and
    Confirm-Proceed. The prompt is stubbed, so every answer is scripted.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-Input'

# Set-PersistedEnvVar is the one call in this module that reaches the
# machine's actual User-scope environment - overridden here so a test
# records what it was asked to persist instead of writing there for real.
# Assigning through the function: drive, not a bare 'function' statement,
# is what makes the replacement stick in the module's own session state
# rather than vanishing with the & scriptblock that installs it.
$inputModule = Get-Module Common-Input
$global:PersistCall = [System.Collections.Generic.List[string]]::new()
& $inputModule {
    ${function:Set-PersistedEnvVar} = {
        param($Name, $Value)
        $global:PersistCall.Add("$Name=$Value")
    }
}

Write-TestSection '1. an environment value is announced, trimmed, and validated'
# Arrange
$env:RI_TEST = '  Public  '

# Act
$value = Resolve-Input -Name V -Prompt 'p' -Choice 'Public', 'Private' -EnvVar 'RI_TEST'

# Assert
Assert-Equal 'trimmed and canonicalised' -Expected 'Public' -Actual $value

# Arrange
$env:RI_TEST = 'garbage'

# Act + Assert
Assert-Throws 'an invalid value throws, naming the variable and the value' `
    -Match "^\`$env:RI_TEST must be one of.*\(got 'garbage'\)$" `
    { Resolve-Input -Name V -Prompt 'p' -Choice 'Public', 'Private' -EnvVar 'RI_TEST' }
Remove-Item Env:RI_TEST

Write-TestSection '2. -Pattern and -Validate apply the same way to either source'
# Arrange
$env:RI_PATTERN = 'nope'

# Act + Assert
Assert-Throws 'a pattern violation via the environment throws' `
    -Match "^\`$env:RI_PATTERN .*\(got 'nope'\)$" `
    {
        Resolve-Input -Name H -Prompt 'p' -Pattern '^https?://\S+$' `
            -Requirement 'must be an http(s) URL' -EnvVar 'RI_PATTERN'
    }

# Arrange
$env:RI_PATTERN = 'https://x.io'

# Act
$value = Resolve-Input -Name H -Prompt 'p' -Pattern '^https?://\S+$' -EnvVar 'RI_PATTERN'

# Assert
Assert-Equal 'a satisfied pattern returns the value' -Expected 'https://x.io' -Actual $value
Remove-Item Env:RI_PATTERN

# Arrange
$seen = [System.Collections.Generic.List[string]]::new()
$validator = { param($v) $seen.Add($v); if ($v -eq 'bad') { 'is not allowed' } }
$env:RI_VALIDATE = 'bad'

# Act + Assert
Assert-Throws '-Validate rejects, naming the source' `
    -Match "^\`$env:RI_VALIDATE is not allowed \(got 'bad'\)$" `
    { Resolve-Input -Name Q -Prompt 'p' -Validate $validator -EnvVar 'RI_VALIDATE' }

# Arrange
$env:RI_VALIDATE = 'good'

# Act
$value = Resolve-Input -Name Q -Prompt 'p' -Validate $validator -EnvVar 'RI_VALIDATE'

# Assert
Assert-Equal '-Validate accepts' -Expected 'good' -Actual $value
Remove-Item Env:RI_VALIDATE

# Arrange
Set-ReadHostAnswer ''

# Act
$value = Resolve-Input -Name Q -Prompt 'p' -Validate $validator

# Assert
Assert-Equal '-Validate is skipped for an empty answer' -Expected '' -Actual $value
Assert-Equal 'the validator saw only the non-empty values' -Expected 'bad,good' `
    -Actual ($seen -join ',')

Write-TestSection '3. -Requirement without -Pattern is a programming error'
# Thrown before anything reads the environment or prompts, so no stub is needed.
Assert-Throws '-Requirement without -Pattern throws' -Match 'has no effect without -Pattern' `
    { Resolve-Input -Name H -Prompt 'p' -Requirement 'must be an http(s) URL' }

Write-TestSection '4. an optional value may be left empty'
# Arrange: nothing in the environment, so this reaches the prompt, and pressing
# enter (an empty answer) is what "leaving it empty" means.
Set-ReadHostAnswer ''

# Act
$value = Resolve-Input -Name H -Prompt 'p' -Pattern '^https?://\S+$'

# Assert
Assert-Equal 'empty is allowed when not required, skipping the other rules' -Expected '' `
    -Actual $value

Write-TestSection '5. a bad prompt answer re-asks instead of throwing'
# Arrange
$warnBefore = Get-ConsoleCounter Warn
Set-ReadHostAnswer 'nope', 'Public'

# Act
$value = Resolve-Input -Name V -Prompt 'p' -Choice 'Public', 'Private'

# Assert
Assert-Equal 'only the good final answer is returned' -Expected 'Public' -Actual $value
Assert-That 'the bad answer was reported' ((Get-ConsoleCounter Warn) -gt $warnBefore)

Write-TestSection '6. -Require rejects an empty first answer like any other bad one'
# Arrange
Set-ReadHostAnswer '', 'ok'

# Act
$value = Resolve-Input -Name N -Prompt 'p' -Require

# Assert
Assert-Equal 'a required prompt re-asks on an empty answer' -Expected 'ok' -Actual $value

Write-TestSection '7. a typed answer is re-cased to match -Choice, as an env value is'
# Arrange
Set-ReadHostAnswer 'private'

# Act
$value = Resolve-Input -Name V -Prompt 'p' -Choice 'Public', 'Private'

# Assert
Assert-Equal 'a prompted answer is canonicalised' -Expected 'Private' -Actual $value

Write-TestSection '8. pressing enter accepts -Default'
# Arrange
Set-ReadHostAnswer ''

# Act
$value = Resolve-Input -Name K -Prompt 'p' -Default 'Code' -Choice 'Template', 'Code'

# Assert
Assert-Equal 'an empty answer falls back to -Default' -Expected 'Code' -Actual $value

Write-TestSection '9. secrets are raw: untrimmed, unvalidated, never echoed'
# Arrange
$env:RI_SECRET = 'from-env'
$global:PersistCall.Clear()

# Act
$value = Resolve-Input -Name T -Prompt 'p' -Secret -EnvVar 'RI_SECRET'

# Assert
Assert-Equal 'a secret from the environment' -Expected 'from-env' -Actual $value
Assert-That 'an already-set variable is never re-persisted' ($global:PersistCall.Count -eq 0) `
($global:PersistCall -join ' | ')
Remove-Item Env:RI_SECRET

# Arrange
Set-ReadHostAnswer 'typed-secret'

# Act
$value = Resolve-Input -Name T -Prompt 'p' -Secret

# Assert
Assert-Equal 'a secret from a prompt' -Expected 'typed-secret' -Actual $value

Write-TestSection '10. a prompted secret is persisted to -EnvVar at User scope'
# Arrange
$global:PersistCall.Clear()
Set-ReadHostAnswer 'fresh-token'
$noise = Get-Narration { $script:persisted = Resolve-Input -Name T -Prompt 'p' `
        -Secret -EnvVar 'RI_PERSIST' }

# Assert
Assert-Equal 'still returns the typed value' -Expected 'fresh-token' -Actual $script:persisted
Assert-Equal 'persisted the answer under -EnvVar''s name' -Expected 'RI_PERSIST=fresh-token' `
    -Actual ($global:PersistCall -join ',')
Assert-Equal 'and updates this process''s own copy too' -Expected 'fresh-token' `
    -Actual $env:RI_PERSIST
Assert-That 'confirms it on the console' ([bool]($noise.Lines -match 'RI_PERSIST')) `
    ($noise.Lines -join ' | ')
Remove-Item Env:RI_PERSIST -ErrorAction SilentlyContinue

# Arrange - declining (a blank answer) must not persist an empty placeholder
$global:PersistCall.Clear()
Set-ReadHostAnswer ''

# Act
$value = Resolve-Input -Name T -Prompt 'p' -Secret -EnvVar 'RI_DECLINE' 6>$null

# Assert
Assert-Equal 'a blank answer is still returned as-is' -Expected '' -Actual $value
Assert-That 'nothing was persisted for a declined secret' ($global:PersistCall.Count -eq 0) `
($global:PersistCall -join ' | ')
Assert-That 'and no variable was created' (-not (Test-Path Env:RI_DECLINE))

# Arrange - no -EnvVar at all means there is nowhere to persist to
$global:PersistCall.Clear()
Set-ReadHostAnswer 'no-home'

# Act
$value = Resolve-Input -Name T -Prompt 'p' -Secret

# Assert
Assert-Equal 'the value is still returned' -Expected 'no-home' -Actual $value
Assert-That 'without -EnvVar there is nothing to persist' ($global:PersistCall.Count -eq 0)

Write-TestSection '11. a whitespace-only environment variable counts as unset'
# Arrange
$env:RI_WS = '   '
Set-ReadHostAnswer ''

# Act
$value = Resolve-Input -Name W -Prompt 'p' -Default 'fallback' -EnvVar 'RI_WS'

# Assert
Assert-Equal 'falls through to the prompt, where the default wins' -Expected 'fallback' `
    -Actual $value

# Arrange
Set-ReadHostAnswer ''

# Act
$value = Resolve-Input -Name W -Prompt 'p' -Secret -EnvVar 'RI_WS'

# Assert
Assert-Equal 'and the same for a secret' -Expected '' -Actual $value
Remove-Item Env:RI_WS

Write-TestSection '12. -Secret cannot be combined with a rule it would ignore'
foreach ($combo in @(
        @{ Label = '-Secret -Require'; Extra = @{ Require = $true } }
        @{ Label = '-Secret -Pattern'; Extra = @{ Pattern = '^x$' } }
        @{ Label = '-Secret -Choice'; Extra = @{ Choice = @('a', 'b') } }
        @{ Label = '-Secret -Validate'; Extra = @{ Validate = { param($v) 'no' } } }
    )) {
    # Arrange
    $extra = $combo.Extra

    # Act + Assert
        Assert-Throws "$($combo.Label) is rejected at bind time" `
        -Match 'Parameter set cannot be resolved' `
        { Resolve-Input -Name T -Prompt 'p' -Secret @extra }
}

Write-TestSection '13. the topic rules'
# Act + Assert
Assert-Equal 'topics normalised, de-duplicated, order kept' -Expected 'b-two, a-one' `
    -Actual (Format-TopicList -Value ' B-Two , a-one, A-ONE ,, b-two ' -Label 'T')
Assert-Equal 'an empty topic list is allowed' -Expected '' `
    -Actual (Format-TopicList -Value '' -Label 'T')
Assert-Equal 'no error for an empty list' -Expected '' -Actual (Get-TopicListError -Value '')
Assert-Equal 'every malformed topic is named' `
    -Expected ("must be lowercase letters, digits and hyphens, starting with a letter or digit: " +
    "'foo bar', '-lead'") `
    -Actual (Get-TopicListError -Value 'Foo Bar, ok, -lead')
Assert-Equal 'an over-length topic is named' `
    -Expected "must be 50 characters or fewer: '$('x' * 51)'" `
    -Actual (Get-TopicListError -Value ('x' * 51))
$twentyOne = (1..21 | ForEach-Object { "t-$_" }) -join ','
$twenty = (1..20 | ForEach-Object { "t-$_" }) -join ','
Assert-Equal '21 topics is rejected' -Expected 'lists 21 topics, but GitHub keeps at most 20' `
    -Actual (Get-TopicListError -Value $twentyOne)
Assert-Equal '20 topics is accepted' -Expected '' -Actual (Get-TopicListError -Value $twenty)
Assert-Throws 'Format-TopicList prepends the label' -Match '^Topics lists 21 topics' `
    { Format-TopicList -Value $twentyOne -Label 'Topics' }

Write-TestSection '14. the slug rule has one wording'
# Act
$requirement = Get-SlugRequirement

# Assert
Assert-That 'the requirement is a real sentence' `
    ($requirement -is [string] -and $requirement.Length -gt 20)
Assert-Throws 'the slug error uses that wording' -Match ([regex]::Escape($requirement)) `
    { Format-Slug -Value 'Not A Slug' -Label 'Name' }

Write-TestSection '15. Confirm-Proceed'
# Arrange
Set-ReadHostAnswer 'yes'

# Act
$answer = Confirm-Proceed -Action 'do it' 6>$null

# Assert
Assert-That "a literal 'yes' proceeds" ($answer -eq $true)

# Arrange
Set-ReadHostAnswer 'y'

# Act
$answer = Confirm-Proceed -Action 'do it' 6>$null

# Assert
Assert-That 'anything else does not' ($answer -eq $false)

Write-TestSection '16. the module surface'
$exported = (Get-Command -Module Common-Input).Name
foreach ($n in 'Get-InputError', 'Assert-InputValid', 'Get-CanonicalChoice', 'Show-InputHint',
    'Read-SecretValue', 'Read-PromptedValue', 'Resolve-KnownValue', 'Split-TopicList',
    'Format-Quoted', 'Set-PersistedEnvVar') {
    Assert-That "$n stays private" ($n -notin $exported)
}

foreach ($n in 'Get-SlugPattern', 'Get-SlugRequirement', 'Format-Slug', 'Get-TopicListError',
    'Format-TopicList', 'Resolve-Input', 'Confirm-Proceed') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
