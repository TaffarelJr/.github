#Requires -Version 7.0
<#
    Tests for Common-VSCode.psm1: the multi-root workspace file and the
    VS Code executable lookup.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-File', 'Common-VSCode'
$vscode = Get-Module Common-VSCode

$root = New-TestRoot -Name 'vscode'

function New-WorkspaceRepo {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Solution = @(),
        [string]$SettingsJson
    )

    $repo = New-TestFolder -Path (Join-Path $root $Name)
    foreach ($relative in $Solution) {
        $path = Join-Path $repo $relative
        New-TestFolder -Path (Split-Path -Parent $path) | Out-Null
        Set-Content -LiteralPath $path -Value '<Solution />' -NoNewline
    }

    if ($PSBoundParameters.ContainsKey('SettingsJson')) {
        $settings = Join-Path (New-TestFolder -Path (Join-Path $repo '.vscode')) 'settings.json'
        Set-Content -LiteralPath $settings -Value $SettingsJson -NoNewline
    }

    return $repo
}

function Get-Pinned {
    param([Parameter(Mandatory)][string]$WorkspaceFile)

    $line = @(Get-Content $WorkspaceFile | Where-Object { $_ -match 'dotnet\.defaultSolution' })
    if ($line.Count -eq 0) { return '(none)' }
    if ($line[0] -match '"dotnet\.defaultSolution":\s*"([^"]*)"') { return $Matches[1] }
    return "(unparsed: $($line[0]))"
}

# Arrange, shared: two ancestor folders every chain-aware case points at.
$chain = @(
    (New-TestFolder -Path (Join-Path $root 'parent-a'))
    (New-TestFolder -Path (Join-Path $root 'parent-b'))
)

Write-TestSection '1. a repo with no solution'
# Arrange
$repo = New-WorkspaceRepo -Name 'no-solution'

# Act
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'no-solution' -ChainPaths $chain
$text = Get-Content -Raw $ws

# Assert
Assert-Equal 'pins disable' -Expected 'disable' -Actual (Get-Pinned $ws)
Assert-That 'lists the repo first, as "."' ($text -match '"name": "no-solution", "path": "\."')
Assert-That 'lists both ancestors relatively' `
(($text -match '"name": "parent-a", "path": "\.\./parent-a"') -and
    ($text -match '"name": "parent-b", "path": "\.\./parent-b"'))
Assert-That 'no backslashes in any path' (-not ($text -match '"path": "[^"]*\\\\'))

Write-TestSection '2. build output is ignored'
# Arrange
$repo = New-WorkspaceRepo -Name 'ignores-bin' `
    -Solution 'App.slnx', 'bin/Ignored.sln', 'obj/Also.sln'

# Act
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'ignores-bin' -ChainPaths $chain

# Assert
Assert-Equal 'pins the real solution' -Expected 'App.slnx' -Actual (Get-Pinned $ws)

Write-TestSection '3. a repo living UNDER a folder named bin'
# Arrange
$repo = New-WorkspaceRepo -Name 'bin/nested-repo' -Solution 'App.sln'

# Act
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'nested-repo' -ChainPaths @()

# Assert
Assert-Equal 'still finds its own solution' -Expected 'App.sln' -Actual (Get-Pinned $ws)

Write-TestSection '4. several solutions: the shallowest wins'
# Arrange
$repo = New-WorkspaceRepo -Name 'many' -Solution 'Zebra.sln', 'src/Alpha.sln'

# Act
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'many' -ChainPaths @()

# Assert
Assert-Equal 'pins the root one, not the alphabetically first' -Expected 'Zebra.sln' `
    -Actual (Get-Pinned $ws)
Assert-That 'says it pinned the shallowest' `
([bool]((Get-Content -Raw $ws) -match '2 solutions found; pinned the shallowest'))

Write-TestSection '5. settings.json is mirrored'
# Arrange
$repo = New-WorkspaceRepo -Name 'mirrors' -SettingsJson @'
{
  "editor.formatOnSave": true,
  "files.trimTrailingWhitespace": true
}
'@

# Act
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'mirrors' -ChainPaths @()
$text = Get-Content -Raw $ws

# Assert
Assert-That 'mirrors both keys' `
(($text -match 'editor\.formatOnSave') -and ($text -match 'files\.trimTrailingWhitespace'))
Assert-That 'the pinned line keeps its comma' ([bool]($text -match '"disable",'))

Write-TestSection '6. settings.json opening with a JSONC comment'
# Arrange
$repo = New-WorkspaceRepo -Name 'jsonc' -SettingsJson @'
// Why these are set, for the next reader.
{
  // keep this inline comment
  "editor.formatOnSave": true
}
'@
$warnBefore = Get-ConsoleCounter Warn

# Act
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'jsonc' -ChainPaths @()
$text = Get-Content -Raw $ws

# Assert
Assert-That 'mirrors it anyway' ([bool]($text -match 'editor\.formatOnSave'))
Assert-That 'keeps the inline comment' ([bool]($text -match 'keep this inline comment'))
Assert-That 'does not warn about a legal JSONC file' ((Get-ConsoleCounter Warn) -eq $warnBefore) `
    "warnings went $warnBefore -> $(Get-ConsoleCounter Warn)"

Write-TestSection '7. a settings.json with no object at all'
# Arrange
$repo = New-WorkspaceRepo -Name 'notjson' -SettingsJson 'just a note, no braces'
$warnBefore = Get-ConsoleCounter Warn

# Act
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'notjson' -ChainPaths @()

# Assert
Assert-That 'warns, naming the file' ((Get-ConsoleCounter Warn) -gt $warnBefore)
Assert-Equal 'still writes a usable workspace' -Expected 'disable' -Actual (Get-Pinned $ws)

Write-TestSection '8. a tab-indented settings.json'
# Arrange
$repo = New-WorkspaceRepo -Name 'tabs' -SettingsJson "{`r`n`t`"editor.formatOnSave`": true`r`n}"

# Act
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'tabs' -ChainPaths @()
$mirrored = @(Get-Content $ws | Where-Object { $_ -match 'editor\.formatOnSave' })[0]

# Assert
Assert-That 'no tab survives into the workspace' (-not $mirrored.Contains("`t")) `
    "line was '$mirrored'"

Write-TestSection '9. an existing file is left alone unless -Force'
# Arrange
$repo = New-WorkspaceRepo -Name 'existing' -Solution 'App.sln'
$ws = Write-WorkspaceFile -RepoPath $repo -RepoName 'existing' -ChainPaths @()
Set-Content -LiteralPath $ws -Value '{ "hand-edited": true }' -NoNewline

# Act
$null = Write-WorkspaceFile -RepoPath $repo -RepoName 'existing' -ChainPaths @()

# Assert
Assert-That 'edits survive a re-run' ((Get-Content -Raw $ws) -match 'hand-edited')

# Act
$null = Write-WorkspaceFile -RepoPath $repo -RepoName 'existing' -ChainPaths @() -Force

# Assert
Assert-That '-Force rewrites it' (-not ((Get-Content -Raw $ws) -match 'hand-edited'))

Write-TestSection '10. a repo reached through a mapped PSDrive'
# Arrange
$repo = New-WorkspaceRepo -Name 'ondrive' -Solution 'App.sln'
$null = New-PSDrive -Name WsLab -PSProvider FileSystem -Root $root -Scope Global

# Act + Assert
try {
    $ws = Write-WorkspaceFile -RepoPath 'WsLab:/ondrive' -RepoName 'ondrive' -ChainPaths @()
    Assert-Equal 'pins the solution correctly' -Expected 'App.sln' -Actual (Get-Pinned $ws)
}
catch { Assert-That 'a PSDrive path does not break it' $false $_.Exception.Message }
finally { Remove-PSDrive WsLab -ErrorAction SilentlyContinue }

Write-TestSection "11. resolving VS Code past a function named 'code'"
# Asserted on the resolver, not through Start-VSCode: launching a real editor
# window is not a test's business. Whether VS Code is installed here is not
# its business either, so $null is an acceptable answer.
# Arrange
function global:code { 'not an executable' }

# Act + Assert
try {
    $exe = & $vscode { Get-VSCodeExecutable }
    Assert-That 'resolves without throwing on a shadowing function' $true
    Assert-That 'and does not return an empty path' ($null -eq $exe -or [bool]$exe) "got '$exe'"
    if ($exe) { Assert-That 'returns something that exists on disk' (Test-Path $exe) "got '$exe'" }
}
catch { Assert-That 'resolves without throwing on a shadowing function' $false `
    $_.Exception.Message }
finally { Remove-Item -Path function:global:code -ErrorAction SilentlyContinue }

Write-TestSection '12. building the launch arguments'
# Arrange + Act
$targetOnly = & $vscode { Get-VSCodeArgument -Target 'ws.code-workspace' }
$withActive = & $vscode {
    Get-VSCodeArgument -Target 'ws.code-workspace' -ActiveFile 'NEXT-STEPS.md'
}
$blankActive = & $vscode { Get-VSCodeArgument -Target 'ws.code-workspace' -ActiveFile '' }

# Assert
Assert-That 'target alone is a single-element list' `
(@($targetOnly).Count -eq 1 -and $targetOnly[0] -eq 'ws.code-workspace') `
    ($targetOnly -join ' | ')
Assert-That 'an active file is appended after the target' `
(@($withActive).Count -eq 2 -and $withActive[0] -eq 'ws.code-workspace' -and
    $withActive[1] -eq 'NEXT-STEPS.md') ($withActive -join ' | ')
Assert-That 'a blank active file is omitted, not passed through' `
(@($blankActive).Count -eq 1) ($blankActive -join ' | ')

Write-TestSection '13. the module surface'
$exported = (Get-Command -Module Common-VSCode).Name
foreach ($n in 'Get-NativePath', 'Get-RelativePosixPath', 'Get-FolderSettingsBlock',
    'Get-WorkspaceFolder', 'Find-Solution', 'Get-WorkspaceSetting', 'Get-VSCodeExecutable',
    'Get-WorkspaceContent', 'Get-VSCodeCandidate', 'Get-VSCodeArgument') {
    Assert-That "$n stays private" ($n -notin $exported)
}

foreach ($n in 'Write-WorkspaceFile', 'Start-VSCode') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
