#Requires -Version 7.0
<#
    Tests for New-Repo-Chain.psm1: locating a repo in its template chain from
    nothing but its remotes.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-Process', 'Common-Git', 'Common-Checklist',
    'Common-GitHub', 'New-Repo-Chain'

$root = New-TestRoot -Name 'chain'

# A bare 'git init' plus remotes is enough: the chain is read from remote URLs,
# never from commits.
function New-LabRepo {
    param([Parameter(Mandatory)][string]$Name, [string]$Origin, [string]$Template)

    $repo = New-TestFolder -Path (Join-Path $root $Name)
    New-TestFolder -Path (Join-Path $repo 'scripts') | Out-Null
    git -C $repo init -q -b main
    if ($Origin) { git -C $repo remote add origin $Origin }
    if ($Template) { git -C $repo remote add template $Template }
    return $repo
}

# Arrange, shared: one three-layer chain plus the odd cases around it. Every
# case only reads these, so they are built once.
$gh = 'https://github.com/TaffarelJr'
$base = New-LabRepo -Name '.github' -Origin "$gh/.github.git"
$mid = New-LabRepo -Name '.template-dotnet' -Origin "$gh/.template-dotnet.git" `
    -Template "$gh/.github.git"
$leaf = New-LabRepo -Name '.template-nuget' `
    -Origin 'git@github.com-personal:TaffarelJr/.template-nuget.git' `
    -Template "$gh/.template-dotnet.git"
$orphan = New-LabRepo -Name 'orphan' -Origin "$gh/orphan.git" -Template "$gh/not-cloned.git"
$noOrigin = New-LabRepo -Name 'no-origin'
$otherOwner = New-LabRepo -Name 'other-owner' -Origin 'https://github.com/Someone/other-owner.git'
$cycleA = New-LabRepo -Name 'cycle-a' -Origin "$gh/cycle-a.git" -Template "$gh/cycle-b.git"
$null = New-LabRepo -Name 'cycle-b' -Origin "$gh/cycle-b.git" -Template "$gh/cycle-a.git"

Write-TestSection '1. Get-TemplateContext reads the origin'
# Act
$ctx = Get-TemplateContext -ScriptRoot (Join-Path $leaf 'scripts')

# Assert
Assert-That 'owner/repo parsed from an SSH-alias URL' `
($ctx.SourceOwnerRepo -eq 'TaffarelJr/.template-nuget') $ctx.SourceOwnerRepo
Assert-That 'SourceUrl is the origin URL verbatim' `
($ctx.SourceUrl -eq 'git@github.com-personal:TaffarelJr/.template-nuget.git') $ctx.SourceUrl
Assert-That 'SourceRoot is the repo, not scripts/' ($ctx.SourceRoot -eq $leaf) $ctx.SourceRoot
Assert-That 'ParentDir is the folder holding the chain' ($ctx.ParentDir -eq $root) $ctx.ParentDir

# Act
$ctx = Get-TemplateContext -ScriptRoot (Join-Path $mid 'scripts')

# Assert
Assert-That 'and from an https URL' ($ctx.SourceOwnerRepo -eq 'TaffarelJr/.template-dotnet') `
    $ctx.SourceOwnerRepo

Write-TestSection '2. Get-TemplateContext on a repo it cannot read'
# Act
$run = Get-Narration { Get-TemplateContext -ScriptRoot (Join-Path $otherOwner 'scripts') }

# Assert
Assert-That 'a different owner is warned about, not refused' `
([bool]($run.Lines -match 'configured owner')) ($run.Lines -join ' | ')
Assert-That 'and the context still comes back' ($run.Output[0].SourceOwner -eq 'Someone')

# Act + Assert
Assert-Throws 'a repo with no origin throws, naming the remote' -Match "'origin'" `
    { Get-TemplateContext -ScriptRoot (Join-Path $noOrigin 'scripts') }
Assert-Throws 'a folder that is not a repo throws' -Match 'No git repo' `
    { Get-TemplateContext -ScriptRoot (Join-Path $root 'nowhere' 'scripts') }

Write-TestSection '3. Get-TemplateChain walks the template remotes'
# Arrange
$global:LASTEXITCODE = 0

# Act
$chain = @(Get-TemplateChain -StartRepoPath $leaf -ParentDir $root)

# Assert
Assert-That 'three layers, nearest first' `
($chain.Count -eq 3 -and $chain[0] -eq $leaf -and $chain[1] -eq $mid -and $chain[2] -eq $base) `
($chain -join ' | ')
Assert-That 'reaching the base leaks no failing exit code' ($LASTEXITCODE -eq 0) `
    "LASTEXITCODE=$LASTEXITCODE"

# Act
$chain = @(Get-TemplateChain -StartRepoPath $base -ParentDir $root)

# Assert
Assert-That 'the base alone is a one-link chain' ($chain.Count -eq 1 -and $chain[0] -eq $base) `
($chain -join ' | ')

Write-TestSection '4. Get-TemplateChain stops where it cannot go on'
# Act
$run = Get-Narration { Get-TemplateChain -StartRepoPath $orphan -ParentDir $root }

# Assert
Assert-That 'an ancestor that is not cloned ends the walk' ($run.Output.Count -eq 1) `
($run.Output -join ' | ')
Assert-That 'and says so' ([bool]($run.Lines -match "isn't cloned locally")) `
    ($run.Lines -join ' | ')

# Act
$chain = @(Get-TemplateChain -StartRepoPath $cycleA -ParentDir $root 6>$null)

# Assert
Assert-That 'a cycle stops at the first repeat' ($chain.Count -eq 2) ($chain -join ' | ')

Write-TestSection '5. Get-NewRepoUrl swaps only the owner/repo'
# Act
$url = Get-NewRepoUrl -SourceUrl 'git@github.com-personal:TaffarelJr/.template-nuget.git' `
    -SourceOwnerRepo 'TaffarelJr/.template-nuget' -NewOwnerRepo 'TaffarelJr/my-lib'

# Assert
Assert-That 'keeps the SSH alias' ($url -eq 'git@github.com-personal:TaffarelJr/my-lib.git') $url

# Act + Assert
Assert-Throws 'a URL without the source owner/repo throws' -Match 'Could not derive' `
    { Get-NewRepoUrl -SourceUrl 'https://x/y.git' -SourceOwnerRepo 'a/b' -NewOwnerRepo 'c/d' }

Write-TestSection '6. the module surface'
$exported = (Get-Command -Module New-Repo-Chain).Name
foreach ($n in 'Get-TemplateContext', 'Get-TemplateChain', 'Get-NewRepoUrl') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
