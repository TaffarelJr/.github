#Requires -Version 7.0
<#
    Tests for Common-Plugin.psm1: discovering, loading, and running the
    New-Repo-<NN>-<slug>.psm1 layer modules.

    Common-Plugin looks for layers beside ITSELF, so each case drops fake layer
    files into the real scripts/ folder and removes them again - the outer
    try/finally makes sure of that even when a case throws.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-Process', 'Common-Git', 'Common-Plugin'

$root = New-TestRoot -Name 'plugin'
$scripts = Get-ScriptsRoot
$fakes = [System.Collections.Generic.List[string]]::new()

function Add-FakeLayer {
    param([Parameter(Mandatory)][string]$Name, [string]$Entry, [string]$Body = '')

    $text = if ($Entry) {
        "function $Entry { param(`$Context) $Body }`r`nExport-ModuleMember -Function $Entry`r`n"
    }
    else {
        "function Get-FakeHelper { 1 }`r`nExport-ModuleMember -Function Get-FakeHelper`r`n"
    }

    $path = Join-Path $scripts $Name
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
    $fakes.Add($path)
}

function Remove-FakeLayer {
    Remove-LayerModule
    foreach ($path in $fakes) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    $fakes.Clear()
}

# Leading comma: an empty result would otherwise unroll to $null on the way out.
function Get-LoadedLayer { , @(Get-Module | Where-Object { $_.Name -match '^New-Repo-\d+-' }) }
function Get-LoadedLayerName { ((Get-LoadedLayer) | ForEach-Object Name) -join ', ' }

function New-LabRepo {
    $lab = Join-Path $root 'lab'
    Remove-TestFolder -Path $lab
    $lab = New-TestFolder -Path $lab
    git -C $lab init -q
    git -C $lab -c user.name=Lab -c user.email=lab@example.com commit -q --allow-empty -m init
    return $lab
}

function Get-Context {
    param([Parameter(Mandatory)][string]$RepoPath)

    return @{
        RepoPath = $RepoPath; RepoName = 'demo'; Kind = 'Code'; OwnerRepo = 'o/demo'
        SourceOwnerRepo = 'o/.github'; Description = 'd'; Homepage = ''; Topics = ''
        Visibility = 'Public'
    }
}

function Invoke-Layer {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][hashtable]$Context
    )

    $run = Get-Narration { Invoke-LayerModule -RepoPath $RepoPath -Context $Context }
    return , $run.Lines
}

try {
    Write-TestSection '1. entry points run in tier order, helpers-only layers are skipped'
    # Arrange
    $lab = New-LabRepo
    $global:Ran = @()
    Add-FakeLayer 'New-Repo-20-c.psm1' 'Invoke-CScaffold' '$global:Ran += "c"'
    Add-FakeLayer 'New-Repo-05-a.psm1' 'Invoke-AScaffold' '$global:Ran += "a"'
    Add-FakeLayer 'New-Repo-10-b.psm1' 'Invoke-BScaffold' '$global:Ran += "b"'
    Add-FakeLayer 'New-Repo-15-helpers.psm1'

    # Act
    $lines = Invoke-Layer -RepoPath $lab -Context (Get-Context -RepoPath $lab)

    # Assert
    Assert-That 'ran a, b, c in tier order' (($global:Ran -join '') -eq 'abc') `
        "ran: $($global:Ran -join '')"
    Assert-That 'the helpers-only layer was reported, not run' `
        ([bool]($lines -match 'helpers only'))
    Assert-That 'each entry point was announced' ([bool]($lines -match 'Invoke-AScaffold'))
    Assert-That 'the layers stay loaded afterwards' ((Get-LoadedLayer).Count -eq 4) `
        "loaded: $(Get-LoadedLayerName)"
    Remove-FakeLayer

    Write-TestSection '2. Remove-LayerModule unloads every layer'
    # Arrange
    $lab = New-LabRepo
    Add-FakeLayer 'New-Repo-10-b.psm1' 'Invoke-BScaffold'
    Add-FakeLayer 'New-Repo-15-helpers.psm1'
    Invoke-Layer -RepoPath $lab -Context (Get-Context -RepoPath $lab) | Out-Null

    # Act
    Remove-LayerModule

    # Assert
    Assert-That 'no layer stays loaded' ((Get-LoadedLayer).Count -eq 0) `
        "still loaded: $(Get-LoadedLayerName)"
    Remove-FakeLayer

    Write-TestSection '3. a tier that is not two digits is refused, not ignored'
    foreach ($bad in 'New-Repo-9-x.psm1', 'New-Repo-100-y.psm1') {
        # Arrange
        $lab = New-LabRepo
        $context = Get-Context -RepoPath $lab
        Add-FakeLayer $bad 'Invoke-BadScaffold'

        # Act + Assert
        Assert-Throws "$bad throws, naming the rule and the file" `
            -Match "(?=.*two digits)(?=.*$([regex]::Escape($bad)))" `
            { Invoke-LayerModule -RepoPath $lab -Context $context 6>$null }
        Assert-That 'Remove-LayerModule does not throw over a malformed file' `
        $(try { Remove-LayerModule; $true } catch { $false })
        Remove-FakeLayer
    }

    Write-TestSection '4. two layers on one tier is ambiguous'
    # Arrange
    $lab = New-LabRepo
    $context = Get-Context -RepoPath $lab
    Add-FakeLayer 'New-Repo-10-b.psm1' 'Invoke-BScaffold'
    Add-FakeLayer 'New-Repo-10-bb.psm1' 'Invoke-BbScaffold'

    # Act + Assert
    Assert-Throws 'a shared tier throws, naming both files' `
        -Match '(?=.*share a tier)(?=.*10-b\.psm1)(?=.*10-bb\.psm1)' `
        { Invoke-LayerModule -RepoPath $lab -Context $context 6>$null }
    Remove-FakeLayer

    Write-TestSection '5. a missing Context key fails before any layer runs'
    # Arrange
    $lab = New-LabRepo
    $global:Ran = @()
    Add-FakeLayer 'New-Repo-10-b.psm1' 'Invoke-BScaffold' '$global:Ran += "b"'
    $partial = Get-Context -RepoPath $lab
    $partial.Remove('Topics')
    $partial.Remove('Homepage')

    # Act + Assert
    Assert-Throws 'a missing key throws, naming every missing key' `
        -Match '(?=.*Topics)(?=.*Homepage)' `
        { Invoke-LayerModule -RepoPath $lab -Context $partial 6>$null }
    Assert-That 'and no layer ran' ($global:Ran.Count -eq 0) "ran: $($global:Ran -join '')"
    Remove-FakeLayer

    Write-TestSection '6. an empty value is fine, only the key is required'
    # Arrange
    $lab = New-LabRepo
    $global:Ran = @()
    Add-FakeLayer 'New-Repo-10-b.psm1' 'Invoke-BScaffold' '$global:Ran += "b"'

    # Act
    Invoke-Layer -RepoPath $lab -Context (Get-Context -RepoPath $lab) | Out-Null

    # Assert
    Assert-That 'empty Homepage and Topics are accepted' (($global:Ran -join '') -eq 'b')
    Remove-FakeLayer

    Write-TestSection '7. pre-existing dirt is reported once, never blamed on a layer'
    # Arrange
    $lab = New-LabRepo
    Set-Content -LiteralPath (Join-Path $lab 'dev-work.txt') -Value 'mine' -NoNewline
    Add-FakeLayer 'New-Repo-10-b.psm1' 'Invoke-BScaffold'

    # Act
    $lines = Invoke-Layer -RepoPath $lab -Context (Get-Context -RepoPath $lab)

    # Assert
        Assert-That 'the developer dirt is mentioned up front' `
        ([bool]($lines -match 'already modified')) `
        ($lines -join ' | ')
    Assert-That 'and is NOT reported as left by a layer' `
        (-not ($lines -match 'changed by a layer')) `
        ($lines -join ' | ')
    Remove-FakeLayer

    Write-TestSection '8. the module surface'
    $exported = (Get-Command -Module Common-Plugin).Name
    foreach ($n in 'Get-LayerModule', 'Import-LayerModule') {
        Assert-That "$n stays private" ($n -notin $exported)
    }

    foreach ($n in 'Invoke-LayerModule', 'Remove-LayerModule') {
        Assert-That "$n is exported" ($n -in $exported)
    }
}
finally {
    Remove-FakeLayer
    Remove-Variable -Name Ran -Scope Global -ErrorAction SilentlyContinue
}

exit (Complete-TestRun)
