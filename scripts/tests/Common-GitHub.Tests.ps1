#Requires -Version 7.0
<#
    Tests for Common-GitHub.psm1: every gh call the scaffolding makes, against
    a stubbed gh, so nothing here touches a real repo or account.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-Process', 'Common-Checklist', 'Common-Input',
    'Common-GitHub'

# Every case starts from a fresh record of gh calls and an empty checklist.
function Reset-Case {
    param([Parameter(Mandatory)][scriptblock]$Gh)

    Set-GhStub -Handler $Gh
    Import-ScriptModule 'Common-Checklist'
}

# The two workflow-permission states gh can report, as its JSON.
$writePermission = '{"default_workflow_permissions":"write",' +
    '"can_approve_pull_request_reviews":false}'
$readPermission = '{"default_workflow_permissions":"read",' +
    '"can_approve_pull_request_reviews":true}'

Write-TestSection '1. New-GitHubRepo reconciles and returns the ACTUAL visibility'
# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @('PRIVATE') } }

# Act
$got = New-GitHubRepo -OwnerRepo 'o/r' -Visibility 'Public' 6>$null

# Assert
Assert-Equal 'an existing PRIVATE repo overrides a typed Public' -Expected 'Private' -Actual $got
Assert-That 'does not attempt to create it' (-not (Test-GhCall 'repo create'))

# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @('PUBLIC') } }

# Act
$got = New-GitHubRepo -OwnerRepo 'o/r' -Visibility 'Public' 6>$null

# Assert
Assert-Equal 'a matching existing repo returns that same value' -Expected 'Public' -Actual $got

# Arrange
Reset-Case { param($a)
    if ($a -contains 'create') { @{ Exit = 0; Out = @() } }
    else { @{ Exit = 1; Out = @('HTTP 404: Not Found') } }
}

# Act
$got = New-GitHubRepo -OwnerRepo 'o/r' -Visibility 'Private' 6>$null

# Assert
Assert-That 'a repo that does not exist yet is created' (Test-GhCall 'repo create')
Assert-Equal 'and returns the requested visibility' -Expected 'Private' -Actual $got

Write-TestSection '2. an owner/repo without a slash is refused before gh is called'
# A slash-less value used to slip through to 'gh repo create noslash', which
# creates the repo under whatever account owns GH_TOKEN.
# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @() } }

# Act + Assert
Assert-Throws 'rejected at bind time, naming the parameter' -Match 'OwnerRepo' `
    { New-GitHubRepo -OwnerRepo 'noslash' -Visibility 'Public' 6>$null }
Assert-That 'and nothing was created' (-not (Test-GhCall 'repo create'))

Write-TestSection '3. Set-WorkflowPermission'
# Arrange
Reset-Case { param($a) @{ Exit = 1; Out = @('{"message":"Bad credentials","status":"401"}') } }

# Act
Set-WorkflowPermission -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'an unreadable GET writes nothing' (-not (Test-GhCall '--method PUT'))
Assert-That 'and queues it for a human' ((Get-ManualItem).Count -eq 1) `
    "checklist has $((Get-ManualItem).Count)"

# Arrange
Reset-Case { param($a)
    if ($a -contains '--method') { @{ Exit = 0; Out = @() } }
    else { @{ Exit = 0; Out = @($writePermission) } }
}

# Act
Set-WorkflowPermission -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That "preserves an existing 'write' default" `
    (Test-GhCall 'default_workflow_permissions=write') `
    ((Get-GhCall) -join ' | ')

# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @($readPermission) } }

# Act
Set-WorkflowPermission -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'already enabled writes nothing' (-not (Test-GhCall '--method PUT'))

Write-TestSection '4. Set-RepoSecret'
# Arrange
Reset-Case { param($a) @{ Exit = 1; Out = @('HTTP 502') } }

# Act
Set-RepoSecret -OwnerRepo 'o/r' -Name 'CODECOV_TOKEN' -Token 'stale-value' 6>$null

# Assert
Assert-That 'an unreadable listing never overwrites' (-not (Test-GhCall 'secret set'))
Assert-That 'and queues it' ((Get-ManualItem).Count -eq 1)

# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @("CODECOV_TOKEN`tUpdated 2026-01-01") } }

# Act
Set-RepoSecret -OwnerRepo 'o/r' -Name 'CODECOV_TOKEN' -Token 'new' 6>$null

# Assert
Assert-That 'an existing secret is left alone' (-not (Test-GhCall 'secret set'))

# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @("OTHER_TOKEN`tUpdated 2026-01-01") } }

# Act
Set-RepoSecret -OwnerRepo 'o/r' -Name 'CODECOV_TOKEN' -Token 'new' 6>$null

# Assert
Assert-That 'a missing secret is set' (Test-GhCall 'secret set CODECOV_TOKEN')
Assert-That 'and its value never reaches the argv' (-not (Test-GhCall 'new'))

# Arrange: the name used to be a live regex, so 'MY.TOKEN' matched a listing
# of MYXTOKEN and the real secret was silently never set.
Reset-Case { param($a) @{ Exit = 0; Out = @("MYXTOKEN`tUpdated 2026-01-01") } }

# Act
Set-RepoSecret -OwnerRepo 'o/r' -Name 'MY.TOKEN' -Token 'v' 6>$null

# Assert
Assert-That 'a name with a regex metacharacter is matched literally' `
    (Test-GhCall 'secret set MY\.TOKEN') `
    ((Get-GhCall) -join ' | ')

Write-TestSection '5. Set-RepoVariable'
# Arrange
Reset-Case { param($a) @{ Exit = 1; Out = @('HTTP 502') } }

# Act
Set-RepoVariable -OwnerRepo 'o/r' -Name 'TEMPLATE_REPO_URL' -Value 'https://x' 6>$null

# Assert
Assert-That 'an unreadable listing never overwrites' (-not (Test-GhCall 'variable set'))

# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @() } }

# Act
Set-RepoVariable -OwnerRepo 'o/r' -Name 'TEMPLATE_REPO_URL' -Value 'https://x' 6>$null

# Assert
Assert-That 'an empty readable listing does set it' (Test-GhCall 'variable set TEMPLATE_REPO_URL')

Write-TestSection '6. Initialize-Topic'
# Arrange
Reset-Case { param($a) @{ Exit = 1; Out = @('{"message":"Not Found"}') } }

# Act + Assert
Assert-That 'an unreadable count does not throw on an [int] cast' `
$(try { Initialize-Topic -OwnerRepo 'o/r' 6>$null; $true } catch { $false })
Assert-That 'and writes no topics' (-not (Test-GhCall '--method PUT'))

# Arrange
Reset-Case { param($a)
    if ($a -contains '--method') { @{ Exit = 0; Out = @() } } else { @{ Exit = 0; Out = @('0') } }
}

# Act
Initialize-Topic -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'seeds when there are none' (Test-GhCall 'names\[\]=github')

# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @('3') } }

# Act
Initialize-Topic -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'skips when topics already exist' (-not (Test-GhCall '--method PUT'))

Write-TestSection '7. Enable-Codeql'
# Arrange
Reset-Case { param($a) @{ Exit = 1; Out = @('{"message":"Bad credentials","status":"401"}') } }

# Act
Enable-Codeql -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'an unreadable setup never PATCHes' (-not (Test-GhCall '--method PATCH'))
Assert-That 'and queues it' ((Get-ManualItem).Count -eq 1)

# Arrange
Reset-Case { param($a)
    if ($a -contains 'PATCH') { @{ Exit = 0; Out = @() } }
    else { @{ Exit = 1; Out = @('{"message":"Not Found","status":"404"}') } }
}

# Act
Enable-Codeql -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'a 404 means not-configured, so it PATCHes' (Test-GhCall '--method PATCH')

# Arrange: a language the chain wants ('csharp') that is not configured yet,
# alongside one somebody enabled by hand ('ruby'). The PATCH replaces the
# list, so ruby has to be carried into it. Fresh import first, so no earlier
# registration leaks in.
Import-ScriptModule 'Common-GitHub'
Add-CodeqlLanguage csharp 6>$null
Reset-Case { param($a)
    if ($a -contains 'PATCH') { @{ Exit = 0; Out = @() } }
    else { @{ Exit = 0; Out = @('configured|actions,ruby') } }
}

# Act
Enable-Codeql -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'adds the new language' (Test-GhCall 'languages\[\]=csharp') ((Get-GhCall) -join ' | ')
Assert-That 'and carries the hand-added one into the PATCH' (Test-GhCall 'languages\[\]=ruby') `
((Get-GhCall) -join ' | ')

# Arrange: fresh import, so the csharp registered above does not leak in here.
Import-ScriptModule 'Common-GitHub'
Reset-Case { param($a) @{ Exit = 0; Out = @('configured|actions') } }

# Act
Enable-Codeql -OwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'nothing to add writes nothing' (-not (Test-GhCall '--method PATCH'))

Write-TestSection '8. Get-CodeqlSetup parses one call'
# Arrange
Reset-Case { param($a) @{ Exit = 0; Out = @('configured|actions,csharp') } }

# Act
$setup = & (Get-Module Common-GitHub) { Get-CodeqlSetup -Endpoint 'x' }

# Assert
Assert-Equal 'reads the state' -Expected 'configured' -Actual $setup.State
Assert-That 'reads both languages' (@($setup.Languages).Count -eq 2) `
    "got $(@($setup.Languages) -join ',')"
Assert-That 'makes exactly one gh call' ((Get-GhCall).Count -eq 1) "made $((Get-GhCall).Count)"

# The next three sections walk one push/pop cycle of the borrowed-account
# state, in order: Use-GhAccount records the caller's state only on the FIRST
# call after a Reset-GhAccount, so each section's Reset is the next one's
# precondition.

Write-TestSection "9. Use-GhAccount records the caller's state once"
# Arrange
$env:GH_TOKEN = 'the-callers-own-token'
Reset-Case { param($a)
    if ($a -contains 'token') { @{ Exit = 0; Out = @('borrowed-token') } }
    elseif ($a -contains 'user') { @{ Exit = 0; Out = @('TaffarelJr') } }
    else { @{ Exit = 0; Out = @() } }
}

# Act
Use-GhAccount -ProbeOwnerRepo 'o/r' 6>$null
Use-GhAccount -ProbeOwnerRepo 'o/r' 6>$null
$prior = & (Get-Module Common-GitHub) { $script:PriorGhToken }
Reset-GhAccount 6>$null

# Assert
Assert-Equal 'a second call keeps the first reading' -Expected 'the-callers-own-token' `
    -Actual $prior
Assert-Equal 'and the reset restores it' -Expected 'the-callers-own-token' -Actual $env:GH_TOKEN
Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue

Write-TestSection '10. Reset-GhAccount reports a switch-back that failed'
# Arrange
Reset-Case { param($a)
    if ($a -contains 'token') { @{ Exit = 0; Out = @('borrowed-token') } }
    elseif ($a -contains 'api' -and $a -contains 'user') { @{ Exit = 0; Out = @('TaffarelJr') } }
    else { @{ Exit = 0; Out = @() } }
}

Use-GhAccount -ProbeOwnerRepo 'o/r' 6>$null
# By reset time the login has changed the active account, and switching back fails.
Reset-Case { param($a)
    if ($a -contains 'switch') { @{ Exit = 1; Out = @('could not switch') } }
    elseif ($a -contains 'api' -and $a -contains 'user') { @{ Exit = 0; Out = @('SomeoneElse') } }
    else { @{ Exit = 0; Out = @() } }
}

$warnBefore = Get-ConsoleCounter Warn

# Act
Reset-GhAccount 6>$null

# Assert
Assert-That 'tries to switch the active account back' `
    (Test-GhCall 'auth switch --user TaffarelJr') `
    ((Get-GhCall) -join ' | ')
Assert-That 'and warns when that fails, instead of claiming success' `
((Get-ConsoleCounter Warn) -gt $warnBefore) "warnings $warnBefore -> $(Get-ConsoleCounter Warn)"
Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue

Write-TestSection '11. no stored token falls through to gh auth login'
# Arrange
$tokenCalls = 0
Reset-Case {
    param($a)
    if ($a -contains 'token') {
        $script:tokenCalls++
        if ($script:tokenCalls -eq 1) { @{ Exit = 1; Out = @('no oauth token') } }
        else { @{ Exit = 0; Out = @('fresh-token') } }
    }
    elseif ($a -contains 'api' -and $a -contains 'user') { @{ Exit = 0; Out = @('TaffarelJr') } }
    else { @{ Exit = 0; Out = @() } }
}

# Act
Use-GhAccount -ProbeOwnerRepo 'o/r' 6>$null

# Assert
Assert-That 'runs gh auth login when there is no stored token' (Test-GhCall 'auth login') `
((Get-GhCall) -join ' | ')
Assert-Equal 'and borrows the token the login stored' -Expected 'fresh-token' -Actual $env:GH_TOKEN
Reset-GhAccount 6>$null
Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue

Write-TestSection '12. the module surface'
$exported = (Get-Command -Module Common-GitHub).Name
foreach ($n in 'Get-ActiveGhAccount', 'Get-CodeqlSetup', 'Set-CodeqlSetup',
    'Write-CodeqlOutcome', 'Register-CodeqlSetupItem', 'Register-UncheckedSetting',
    'Get-GhToken', 'Request-GhLogin', 'Test-GhAdminAccess', 'Restore-GhAccount',
    'Get-ManualGitHubSetting', 'Get-CodeqlTargetLanguage') {
    Assert-That "$n stays private" ($n -notin $exported)
}

foreach ($n in 'Invoke-Gh', 'Invoke-GhRead', 'Get-RepoOwner', 'Add-CodeqlLanguage',
    'New-GitHubRepo', 'Set-WorkflowPermission', 'Set-RepoSecret', 'Set-RepoVariable',
    'Initialize-Topic', 'Enable-Codeql', 'Use-GhAccount', 'Reset-GhAccount') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
