#Requires -Version 7.0
<#
    Tests for New-Repo-Files.psm1: rewriting a freshly cloned repo's inherited
    files - settings.yml, LICENSE, README, the template-only files - into its
    own.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-File', 'Common-Text', 'New-Repo-Files'

$root = New-TestRoot -Name 'files'

function New-Repo {
    param([Parameter(Mandatory)][string]$Name)

    return New-TestFolder -Path (Join-Path $root $Name)
}

function Write-RepoFile {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Relative,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [System.Text.Encoding]$Encoding = [System.Text.UTF8Encoding]::new($false)
    )

    $path = Join-Path $Repo $Relative
    New-TestFolder -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, $Encoding)
}

function Get-RepoText {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Relative)

    return [System.IO.File]::ReadAllText((Join-Path $Repo $Relative))
}

# LF-normalised: in .NET multiline mode `$` matches before \n, so a CRLF file
# leaves a \r that no `(?m)^...$` pattern would match.
function Get-RepoLf {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Relative)

    return (Get-RepoText -Repo $Repo -Relative $Relative) -replace "`r`n", "`n"
}

function Write-Settings {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [string]$Visibility = 'Public',
        [string]$Homepage = '',
        [string]$Topics = 'dotnet, tool'
    )

    Write-SettingsFile -RepoPath $Repo -Kind $Kind -Name $Name -ExtendsRepo '.template-dotnet' `
        -Description "A $Kind repo" -Homepage $Homepage -Topics $Topics `
        -Visibility $Visibility 6>$null
}

$settingsFile = '.github/settings.yml'

Write-TestSection '1. Write-SettingsFile: every Kind and Visibility writes a usable file'
foreach ($case in @(
        @{ Kind = 'Template'; Vis = 'Public'; Home = 'https://example.org' }
        @{ Kind = 'Template'; Vis = 'Private'; Home = '' }
        @{ Kind = 'Code'; Vis = 'Public'; Home = '' }
        @{ Kind = 'Code'; Vis = 'Private'; Home = 'https://example.org' }
    )) {
    # Arrange
    $name = "$($case.Kind)-$($case.Vis)".ToLowerInvariant()
    $repo = New-Repo -Name $name
    $before = Get-ChangeCount

    # Act
    Write-Settings -Repo $repo -Kind $case.Kind -Name $name `
        -Visibility $case.Vis -Homepage $case.Home
    $text = Get-RepoLf -Repo $repo -Relative $settingsFile

    # Assert
    Assert-That "${name}: extends the parent" ($text -match '(?m)^_extends: \.template-dotnet$')
    Assert-That "${name}: names itself" ($text -match "(?m)^  name: $([regex]::Escape($name))$")
    Assert-That "${name}: carries the description" `
        ($text -match "(?m)^  description: A $($case.Kind) repo$")
    Assert-That "${name}: carries the topics" ($text -match '(?m)^  topics: dotnet, tool$')
    Assert-That "${name}: recorded a change" ((Get-ChangeCount) -gt $before)
    if ($case.Home) {
        Assert-That "${name}: homepage is a real key" `
            ($text -match '(?m)^  homepage: https://example\.org$')
    }
    else {
        Assert-That "${name}: absent homepage stays a comment" `
            ($text -match '(?m)^  # homepage: \(none\)$')
    }

    $wantPrivate = $case.Vis -eq 'Private'
    Assert-That "${name}: private line only when private" `
    (($text -match '(?m)^  private: true$') -eq $wantPrivate)
    $wantLeaf = $case.Kind -eq 'Code'
    Assert-That "${name}: is_template only for a leaf" `
        (($text -match '(?m)^  is_template: false$') -eq $wantLeaf)
    Assert-That "${name}: merge policy only for a leaf" `
    (($text -match '(?m)^  allow_merge_commit: true$') -eq $wantLeaf)
    Assert-That "${name}: rulesets block only for a leaf" `
        (($text -match '(?m)^rulesets:$') -eq $wantLeaf)
}

Write-TestSection '2. Write-SettingsFile: the leaf file is valid YAML with a top-level ruleset'
# Arrange
$repo = New-Repo -Name 'leaf-yaml'

# Act
Write-Settings -Repo $repo -Kind Code -Name 'leaf-yaml'
$lines = @(Get-Content (Join-Path $repo $settingsFile))

# Assert
Assert-That 'no tab characters' (-not ($lines -match "`t"))
Assert-That 'repository: is top-level' ([bool]($lines -match '^repository:$'))
Assert-That 'rulesets: is top-level, not nested under repository:' `
    ([bool]($lines -match '^rulesets:$'))
$ruleIndex = [array]::IndexOf($lines, 'rulesets:')
Assert-That 'the ruleset entry follows it' ($lines[$ruleIndex + 1] -match '^\s+#|^\s+- name:')

Write-TestSection '3. Write-SettingsFile: a re-run on the same repo skips'
# Arrange
$repo = New-Repo -Name 'rerun'
Write-Settings -Repo $repo -Kind Code -Name 'rerun'
$before = Get-ChangeCount

# Act
$run = Get-Narration {
    Write-SettingsFile -RepoPath $repo -Kind Code -Name 'rerun' -ExtendsRepo '.template-dotnet' `
        -Description 'A Code repo' -Homepage '' -Topics 'dotnet, tool' -Visibility Public
}

# Assert
Assert-That 'says it already targets this repo' ([bool]($run.Lines -match 'already targets')) `
($run.Lines -join ' | ')
Assert-That 'and records no change' ((Get-ChangeCount) -eq $before)

Write-TestSection '4. Write-SettingsFile: a file naming a DIFFERENT repo is overwritten'
# Arrange: the parent's settings.yml, as a fresh clone inherits it.
$repo = New-Repo -Name 'renamed'
Write-Settings -Repo $repo -Kind Code -Name 'the-parent'
$before = Get-ChangeCount

# Act
Write-Settings -Repo $repo -Kind Code -Name 'renamed'

# Assert
Assert-That "the parent's settings.yml does not survive" `
((Get-RepoLf -Repo $repo -Relative $settingsFile) -match '(?m)^  name: renamed$')
Assert-That 'and it records a change' ((Get-ChangeCount) -gt $before)

Write-TestSection '5. Write-SettingsFile: an empty topic list is legal'
# Arrange
$repo = New-Repo -Name 'no-topics'

# Act + Assert
$threw = $false
try { Write-Settings -Repo $repo -Kind Code -Name 'no-topics' -Topics '' } catch { $threw = $true }
Assert-That 'empty topics does not throw' (-not $threw)
Assert-That 'and writes an empty topics key' `
((Get-RepoLf -Repo $repo -Relative $settingsFile) -match '(?m)^  topics:\s*$')

Write-TestSection "6. Write-SettingsFile: a rewrite keeps the file's own line ending"
# An LF file beside a CRLF README must not be dragged to CRLF: the file's own
# ending wins over the sibling's when the file already exists.
# Arrange
$repo = New-Repo -Name 'eol'
Write-RepoFile -Repo $repo -Relative 'README.md' -Text "# eol Repository`r`n"
Write-RepoFile -Repo $repo -Relative $settingsFile -Text "_extends: x`nrepository:`n  name: other`n"

# Act
Write-Settings -Repo $repo -Kind Code -Name 'eol' -Visibility Private
$text = Get-RepoText -Repo $repo -Relative $settingsFile

# Assert
Assert-That 'an LF settings.yml stays LF, even beside a CRLF README' (-not $text.Contains("`r"))
Assert-That 'and was rewritten' ($text -match '(?m)^  name: eol$')

# Arrange: no settings.yml yet, only an LF README beside where it will go.
$repo = New-Repo -Name 'eol-new'
Write-RepoFile -Repo $repo -Relative 'README.md' -Text "# eol-new Repository`n"

# Act
Write-Settings -Repo $repo -Kind Template -Name 'eol-new'
$text = Get-RepoText -Repo $repo -Relative $settingsFile
$firstByte = [System.IO.File]::ReadAllBytes((Join-Path $repo $settingsFile))[0]

# Assert
Assert-That 'a brand-new settings.yml follows the README beside it' `
(-not $text.Contains("`r") -and $text.Contains("`n"))
Assert-That 'and has no BOM' ($firstByte -ne 0xEF)

Write-TestSection '7. Write-SettingsFile: the name check is anchored to one line'
# The old '\s*$' could run across a line break, so a name that merely
# PREFIXED the real one could read as a match.
# Arrange
$repo = New-Repo -Name 'name-anchor'
Write-RepoFile -Repo $repo -Relative $settingsFile `
    -Text "_extends: x`r`nrepository:`r`n  name: anchor-longer`r`n"
$before = Get-ChangeCount

# Act
Write-Settings -Repo $repo -Kind Code -Name 'anchor'

# Assert
Assert-That 'a name that is only a prefix of the existing one is overwritten' `
    ((Get-ChangeCount) -gt $before)
Assert-That 'with the new name' `
    ((Get-RepoLf -Repo $repo -Relative $settingsFile) -match '(?m)^  name: anchor$')

Write-TestSection '8. Set-RepoLicense'
# Arrange
$repo = New-Repo -Name 'licence'
$mit = "MIT License`r`n`r`nCopyright (c) 2025 RJ Hollberg`r`n`r`n" +
    "Permission is hereby granted...`r`n"
Write-RepoFile -Repo $repo -Relative 'LICENSE' -Text $mit
$before = Get-ChangeCount

# Act
Set-RepoLicense -RepoPath $repo -Visibility Public 6>$null

# Assert
Assert-That 'a public repo keeps MIT' `
    ((Get-RepoText -Repo $repo -Relative 'LICENSE') -match 'MIT License')
Assert-That 'and records no change' ((Get-ChangeCount) -eq $before)

# Arrange
$before = Get-ChangeCount

# Act
Set-RepoLicense -RepoPath $repo -Visibility Private 6>$null
$licence = Get-RepoText -Repo $repo -Relative 'LICENSE'

# Assert
Assert-That 'a private repo gets the proprietary notice' ($licence -match '^All Rights Reserved')
Assert-That 'the copyright line is carried over verbatim' `
    ($licence -match 'Copyright \(c\) 2025 RJ Hollberg')
Assert-That 'the CRLF ending is kept' ($licence.Contains("`r`n"))
Assert-That 'and it records a change' ((Get-ChangeCount) -gt $before)

# Arrange
$before = Get-ChangeCount

# Act
Set-RepoLicense -RepoPath $repo -Visibility Private 6>$null

# Assert
Assert-That 'a second pass skips' ((Get-ChangeCount) -eq $before)

# Arrange
$repo = New-Repo -Name 'licence-noholder'
Write-RepoFile -Repo $repo -Relative 'LICENSE' -Text "MIT License`n`nno holder here`n"

# Act
$run = Get-Narration { Set-RepoLicense -RepoPath $repo -Visibility Private }
$licence = Get-RepoText -Repo $repo -Relative 'LICENSE'

# Assert
Assert-That 'a LICENSE with no copyright line warns' `
    ([bool]($run.Lines -match 'No copyright line')) `
    ($run.Lines -join ' | ')
Assert-That 'and still gets a notice, with this year' `
($licence -match "(?m)^Copyright \(c\) $((Get-Date).Year)\r?$")
Assert-That 'keeping its LF ending' (-not $licence.Contains("`r"))

Write-TestSection '9. Remove-ScriptsFolder'
# Arrange
$repo = New-Repo -Name 'scripts-repo'
Write-RepoFile -Repo $repo -Relative 'scripts/x.psm1' -Text 'x'
Write-RepoFile -Repo $repo -Relative '.github/workflows/test-scripts.yml' -Text 'y'
$before = Get-ChangeCount

# Act
Remove-ScriptsFolder -RepoPath $repo 6>$null

# Assert
Assert-That 'scripts/ is gone' (-not (Test-Path (Join-Path $repo 'scripts')))
Assert-That 'and its CI workflow too' `
    (-not (Test-Path (Join-Path $repo '.github/workflows/test-scripts.yml')))
Assert-That 'and it records a change' ((Get-ChangeCount) -gt $before)

# Arrange
$before = Get-ChangeCount

# Act
$run = Get-Narration { Remove-ScriptsFolder -RepoPath $repo }

# Assert
Assert-That 'a second pass says so instead of printing nothing' `
    ([bool]($run.Lines -match 'already removed'))
Assert-That 'and records no change' ((Get-ChangeCount) -eq $before)

Write-TestSection '10. Remove-TemplateOnlyFile'
# Arrange
$repo = New-Repo -Name 'template-only'
foreach ($relative in '.github/FUNDING.yml', '.github/ISSUE_TEMPLATE/config.yml',
    '.github/ISSUE_TEMPLATE/bug.yml') {
    Write-RepoFile -Repo $repo -Relative $relative -Text 'x'
}

$before = Get-ChangeCount

# Act
$run = Get-Narration { Remove-TemplateOnlyFile -RepoPath $repo }

# Assert
Assert-That 'FUNDING.yml is gone' (-not (Test-Path (Join-Path $repo '.github/FUNDING.yml')))
Assert-That 'the issue chooser is gone' `
(-not (Test-Path (Join-Path $repo '.github/ISSUE_TEMPLATE/config.yml')))
Assert-That 'an ordinary issue form is kept' `
    (Test-Path (Join-Path $repo '.github/ISSUE_TEMPLATE/bug.yml'))
Assert-That 'recorded a change' ((Get-ChangeCount) -gt $before)
Assert-That 'names each file it deleted' `
    ([bool]($run.Lines -match 'FUNDING\.yml') -and [bool]($run.Lines -match 'config\.yml')) `
    ($run.Lines -join ' | ')

# Arrange
$before = Get-ChangeCount

# Act
$run = Get-Narration { Remove-TemplateOnlyFile -RepoPath $repo }

# Assert
Assert-That 'a second pass records nothing' ((Get-ChangeCount) -eq $before)
Assert-That 'and says so' ([bool]($run.Lines -match 'none left')) ($run.Lines -join ' | ')

# Arrange: only one of the two is present.
$repo = New-Repo -Name 'template-only-partial'
Write-RepoFile -Repo $repo -Relative '.github/FUNDING.yml' -Text 'x'

# Act
$run = Get-Narration { Remove-TemplateOnlyFile -RepoPath $repo }

# Assert
Assert-That 'deletes what is there and counts only that' ([bool]($run.Lines -match '1 file\(s\)')) `
($run.Lines -join ' | ')

# The two markers Test-TemplateReadme looks for, taken from the real README.
$templateReadme = @'
# .github Repository

```mermaid
---
title: Personal GitHub Repo Structure
---
  class github current
```

## Description of Files in This Template Repo
'@

Write-TestSection '11. Reset-Readme replaces a template README'
foreach ($case in @(
        @{ Name = 'pub-desc'; Vis = 'Public'; Desc = 'Does a useful thing.' }
        @{ Name = 'pub-nodesc'; Vis = 'Public'; Desc = '' }
        @{ Name = 'priv-desc'; Vis = 'Private'; Desc = 'Internal tool.' }
    )) {
    # Arrange
    $repo = New-Repo -Name $case.Name
    Write-RepoFile -Repo $repo -Relative 'README.md' -Text $templateReadme
    $before = Get-ChangeCount

    # Act
    Reset-Readme -RepoPath $repo -RepoName $case.Name -Description $case.Desc `
        -Visibility $case.Vis 6>$null
    $text = Get-RepoText -Repo $repo -Relative 'README.md'

    # Assert
    Assert-That "$($case.Name): titled after the repo" ($text -match "^# $($case.Name) ")
    Assert-That "$($case.Name): template content gone" `
        (-not ($text -match 'Personal GitHub Repo Structure'))
    Assert-That "$($case.Name): recorded a change" ((Get-ChangeCount) -gt $before)
    $wantLicence = if ($case.Vis -eq 'Private') { 'All rights reserved' } else { '\[MIT\]' }
    Assert-That "$($case.Name): licence section matches visibility" ($text -match $wantLicence)
    $wantDesc = if ($case.Desc) { [regex]::Escape($case.Desc) } else { 'TODO: what this is' }
    Assert-That "$($case.Name): description or a TODO" ($text -match $wantDesc)
    $undefined = @('cocFile', 'contribFile', 'licenseFile', 'securityFile', 'supportFile' |
            Where-Object { $text -match "\[$_\]" -and -not ($text -match "(?m)^\[$_\]:") })
    Assert-That "$($case.Name): every link reference used is defined" ($undefined.Count -eq 0) `
        "undefined: $($undefined -join ', ')"
}

Write-TestSection '12. Reset-Readme leaves any other README alone'
# Arrange
$repo = New-Repo -Name 'already-mine'
Write-RepoFile -Repo $repo -Relative 'README.md' -Text "# My Project`r`n`r`nHand written.`r`n"
$before = Get-ChangeCount

# Act
Reset-Readme -RepoPath $repo -RepoName 'already-mine' -Description 'x' -Visibility Public 6>$null

# Assert
Assert-That 'the hand-written README survives' `
((Get-RepoText -Repo $repo -Relative 'README.md') -match 'Hand written')
Assert-That 'and no change is recorded' ((Get-ChangeCount) -eq $before)

# Arrange
$repo = New-Repo -Name 'no-readme'

# Act + Assert
$threw = $false
try {
    Reset-Readme -RepoPath $repo -RepoName 'no-readme' -Description 'x' -Visibility Public 6>$null
}
catch { $threw = $true }
Assert-That 'no README at all skips rather than throwing' (-not $threw)

Write-TestSection '13. Update-Readme de-links the template-only rows'
# Arrange
$repo = New-Repo -Name 'delink'
Write-RepoFile -Repo $repo -Relative 'README.md' -Text @'
| File | Exists only in<br/>.github repo |
| ---- | ------------------------------- |
| [FUNDING.yml][fundingFile] | ✅ |
| [config.yml][issueChooserFile] | ✅ |
| [Something else][keepFile] | |

[fundingFile]: ./.github/FUNDING.yml
[issueChooserFile]: ./.github/ISSUE_TEMPLATE/config.yml
[keepFile]: ./somewhere.md
'@
$before = Get-ChangeCount

# Act
Update-Readme -RepoPath $repo 6>$null
$text = Get-RepoText -Repo $repo -Relative 'README.md'

# Assert
Assert-That 'the row text survives' ($text -match 'FUNDING\.yml')
Assert-That 'but the link is gone' (-not ($text -match '\[fundingFile\]'))
Assert-That 'the orphaned definition is collected' `
    (-not ($text -match 'ISSUE_TEMPLATE/config\.yml'))
Assert-That 'a still-used definition is kept' ($text -match '\[keepFile\]: \./somewhere\.md')
Assert-That 'recorded a change' ((Get-ChangeCount) -gt $before)

# Arrange
$before = Get-ChangeCount

# Act
Update-Readme -RepoPath $repo 6>$null

# Assert
Assert-That 'a second pass records nothing' ((Get-ChangeCount) -eq $before)

Write-TestSection '14. Set-ReadmeTitle'
# Arrange
$repo = New-Repo -Name 'retitle'
Write-RepoFile -Repo $repo -Relative 'README.md' `
    -Text "# .github Repository <!-- omit from toc -->`r`n`r`nbody`r`n"
$before = Get-ChangeCount

# Act
Set-ReadmeTitle -RepoPath $repo -RepoName '.template-x' 6>$null
$text = Get-RepoText -Repo $repo -Relative 'README.md'

# Assert
Assert-That 'the heading names the new repo' ($text -match '^# \.template-x Repository')
Assert-That 'the toc marker survives' ($text -match 'omit from toc')
Assert-That 'recorded a change' ((Get-ChangeCount) -gt $before)

# Arrange
$before = Get-ChangeCount

# Act
Set-ReadmeTitle -RepoPath $repo -RepoName '.template-x' 6>$null

# Assert
Assert-That 'a second pass records nothing' ((Get-ChangeCount) -eq $before)

Write-TestSection '15. Update-ReadmeDiagram'
# Arrange
$repo = New-Repo -Name 'diagram'
Write-RepoFile -Repo $repo -Relative 'README.md' -Text "# x`r`n`r`nclass github current`r`n"
$before = Get-ChangeCount

# Act
Update-ReadmeDiagram -RepoPath $repo 6>$null

# Assert
Assert-That 'the diagram points at the template row' `
((Get-RepoText -Repo $repo -Relative 'README.md') -match 'class templateB current')
Assert-That 'recorded a change' ((Get-ChangeCount) -gt $before)

# Arrange
$before = Get-ChangeCount

# Act
Update-ReadmeDiagram -RepoPath $repo 6>$null

# Assert
Assert-That 'a second pass records nothing' ((Get-ChangeCount) -eq $before)

Write-TestSection '16. Update-RepoReference preserves encoding, and says when there is nothing left'
# Arrange
$repo = New-Repo -Name 'refs'
Write-RepoFile -Repo $repo -Relative 'CONTRIBUTING.md' -Text 'See TaffarelJr/.github for more.' `
    -Encoding ([System.Text.UTF8Encoding]::new($true))
Write-RepoFile -Repo $repo -Relative 'SECURITY.md' -Text 'Nothing to change here.'
$before = Get-ChangeCount

# Act
Update-RepoReference -RepoPath $repo -OldOwnerRepo 'TaffarelJr/.github' `
    -NewOwnerRepo 'TaffarelJr/.template-x' 6>$null
$contrib = [System.IO.File]::ReadAllBytes((Join-Path $repo 'CONTRIBUTING.md'))

# Assert
Assert-That 'the reference is retargeted' `
((Get-RepoText -Repo $repo -Relative 'CONTRIBUTING.md') -match '\.template-x')
Assert-That 'the UTF-8 BOM survives' ($contrib[0] -eq 0xEF -and $contrib[1] -eq 0xBB)
Assert-That 'recorded a change' ((Get-ChangeCount) -gt $before)

# Arrange
$before = Get-ChangeCount

# Act
$run = Get-Narration {
    Update-RepoReference -RepoPath $repo -OldOwnerRepo 'TaffarelJr/.github' `
        -NewOwnerRepo 'TaffarelJr/.template-x'
}

# Assert
Assert-That 'a second pass records nothing' ((Get-ChangeCount) -eq $before)
Assert-That 'and says so instead of printing nothing' `
    ([bool]($run.Lines -match 'no .* references left')) `
    ($run.Lines -join ' | ')

Write-TestSection '17. the module surface'
$exported = (Get-Command -Module New-Repo-Files).Name
foreach ($n in 'Test-TemplateReadme', 'Get-ProjectReadme', 'Get-ProprietaryLicense',
    'Get-SettingsAboutBlock', 'Get-SettingsGeneralBlock', 'Get-SettingsLeafBlock') {
    Assert-That "$n stays private" ($n -notin $exported)
}

foreach ($n in 'Remove-TemplateOnlyFile', 'Remove-ScriptsFolder', 'Update-RepoReference',
    'Update-Readme', 'Update-ReadmeDiagram', 'Set-ReadmeTitle', 'Reset-Readme', 'Set-RepoLicense',
    'Write-SettingsFile') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
