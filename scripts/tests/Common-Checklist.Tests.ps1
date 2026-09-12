#Requires -Version 7.0
<#
    Tests for Common-Checklist.psm1: queueing the manual follow-ups and showing
    them grouped at the end of a run.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-File', 'Common-Checklist'

function Reset-Checklist { Import-ScriptModule 'Common-Checklist' }

$root = New-TestRoot -Name 'checklist'

Write-TestSection '1. nothing queued'
# Arrange
Reset-Checklist

# Act
$run = Get-Narration { Show-ManualChecklist -OwnerRepo 'o/r' }

# Assert
Assert-That 'says there is nothing to do' ([bool]($run.Lines -cmatch 'No manual follow-up needed'))
Assert-That 'and shows no banner' (-not ($run.Lines -cmatch 'MANUAL FOLLOW-UP')) `
    ($run.Lines -join ' | ')

Write-TestSection '2. items are grouped by category and numbered within it'
# Arrange
Reset-Checklist
$quiet = Get-Narration {
    Add-ManualItem -Category 'GitHub' -Title 'Enable immutable releases'
    Add-ManualItem -Category 'Codecov' -Title 'Add the token' -Steps 'Open the settings', 'Paste it'
    Add-ManualItem -Category 'GitHub' -Title 'Check the rulesets'
}

# Act
$run = Get-Narration { Show-ManualChecklist -OwnerRepo 'o/r' }
$lines = $run.Lines

# Assert
Assert-That 'queueing prints nothing' ($quiet.Lines.Count -eq 0) ($quiet.Lines -join ' | ')
Assert-That 'the banner names the repo' ([bool]($lines -cmatch 'MANUAL FOLLOW-UP — o/r'))
Assert-That 'each category has one heading' (@($lines -match '^  ▸ ').Count -eq 2) `
    ($lines -join ' | ')
Assert-That 'items are numbered within their category, in the order added' `
([bool]($lines -match '^    1\. \[ \] Enable immutable releases$') -and
    [bool]($lines -match '^    2\. \[ \] Check the rulesets$')) ($lines -join ' | ')
Assert-That 'and the numbering restarts per category' `
    ([bool]($lines -match '^    1\. \[ \] Add the token$'))
Assert-That 'steps sit under the title, one per line' `
    ([bool]($lines -match '^ {11}Open the settings$') -and
    [bool]($lines -match '^ {11}Paste it$')) `
    ($lines -join ' | ')
Assert-That 'the queue is what Get-ManualItem sees' ((Get-ManualItem).Count -eq 3)

Write-TestSection '3. a category is matched by its text, ignoring case'
# Arrange
Reset-Checklist
Add-ManualItem -Category 'GitHub' -Title 'a'
Add-ManualItem -Category 'github' -Title 'b'
Add-ManualItem -Category 'Git Hub' -Title 'c'

# Act
$run = Get-Narration { Show-ManualChecklist -OwnerRepo 'o/r' }

# Assert
Assert-That 'a different casing joins the same heading, a different spelling does not' `
(@($run.Lines -match '^  ▸ ').Count -eq 2) ($run.Lines -join ' | ')
Assert-That 'the heading takes the spelling first seen' `
    ([bool]($run.Lines -cmatch '^  ▸ GitHub$')) `
    ($run.Lines -join ' | ')

Write-TestSection '4. nothing queued writes no file'
# Arrange
Reset-Checklist
$repo = New-TestFolder -Path (Join-Path $root 'empty')

# Act
$path = Write-ManualChecklistFile -RepoPath $repo

# Assert
Assert-That 'returns $null' ($null -eq $path)
Assert-That 'and NEXT-STEPS.md is not created' `
(-not (Test-Path -LiteralPath (Join-Path $repo 'NEXT-STEPS.md')))

Write-TestSection '5. queued items render as a Markdown checklist'
# Arrange
Reset-Checklist
$repo = New-TestFolder -Path (Join-Path $root 'queued')
Add-ManualItem -Category 'GitHub' -Title 'Enable immutable releases'
Add-ManualItem -Category 'Codecov' -Title 'Add the token' -Steps 'Open the settings', 'Paste it'
Add-ManualItem -Category 'GitHub' -Title 'Check the rulesets'

# Act
$path = Write-ManualChecklistFile -RepoPath $repo
$lines = Get-Content -LiteralPath $path

# Assert
Assert-Equal 'writes NEXT-STEPS.md at the repo root' `
    -Expected (Join-Path $repo 'NEXT-STEPS.md') -Actual $path
Assert-That 'each category is its own heading' (@($lines -match '^## ').Count -eq 2) `
    ($lines -join ' | ')
Assert-That 'each item is an unchecked box' `
([bool]($lines -match '^- \[ \] Enable immutable releases$') -and
    [bool]($lines -match '^- \[ \] Check the rulesets$') -and
    [bool]($lines -match '^- \[ \] Add the token$')) ($lines -join ' | ')
Assert-That 'steps sit indented under the title' `
([bool]($lines -match '^      Open the settings$') -and
    [bool]($lines -match '^      Paste it$')) ($lines -join ' | ')

Write-TestSection '6. a second run overwrites rather than appends'
# Arrange - $repo and its file still exist from section 5
Reset-Checklist
Add-ManualItem -Category 'GitHub' -Title 'Only this one now'

# Act
$path = Write-ManualChecklistFile -RepoPath $repo
$lines = Get-Content -LiteralPath $path

# Assert
Assert-That 'the stale item is gone' (-not ($lines -match 'Enable immutable releases')) `
    ($lines -join ' | ')
Assert-That 'only the current queue is written' ([bool]($lines -match 'Only this one now'))

Write-TestSection '7. the module surface'
$exported = (Get-Command -Module Common-Checklist).Name
foreach ($n in 'Add-ManualItem', 'Show-ManualChecklist', 'Write-ManualChecklistFile') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
