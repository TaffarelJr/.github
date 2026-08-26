#Requires -Version 7.0
<#
    Tests for Common-Text.psm1: Rename-Token over a tree of mixed encodings,
    binaries, and excluded folders.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-File', 'Common-Text'

$root = New-TestRoot -Name 'text'
# The repo deliberately lives under a folder named 'scripts', which is on the
# exclude list: pre-fix, that alone excluded the entire tree.
$repo = Join-Path $root 'scripts' 'MyRepo'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$nupkgBytes = [byte[]]@(0x50, 0x4B, 0x03, 0x04) +
[System.Text.Encoding]::ASCII.GetBytes('Placeholder') + [byte[]]@(0x00, 0x01)

function Get-RepoPath {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Part)

    $path = $repo
    foreach ($segment in $Part) { $path = Join-Path $path $segment }
    return $path
}

function Get-RepoText {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Part)

    return [System.IO.File]::ReadAllText((Get-RepoPath @Part))
}

function Get-RepoBytes {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Part)

    return [System.IO.File]::ReadAllBytes((Get-RepoPath @Part))
}

function Write-RepoText {
    param(
        [Parameter(Mandatory)][string[]]$Part,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [System.Text.Encoding]$Encoding = $utf8
    )

    $path = Get-RepoPath @Part
    New-TestFolder -Path (Split-Path -Parent $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, $Encoding)
}

function New-Lab {
    Remove-TestFolder -Path $repo
    Write-RepoText -Part 'src', 'Placeholder', 'Placeholder.cs' `
        -Text "namespace Placeholder;`r`nclass Placeholder { }`r`n"
    Write-RepoText -Part 'src', 'Placeholder', 'Plain.cs' -Text "// Placeholder`r`n"
    Write-RepoText -Part 'MyRepo.slnx' -Text '<Project Path="Placeholder" />' `
        -Encoding ([System.Text.UTF8Encoding]::new($true))
    Write-RepoText -Part 'utf16.txt' -Text 'Placeholder here' `
        -Encoding ([System.Text.UnicodeEncoding]::new($false, $true))
    Write-RepoText -Part 'bin', 'Placeholder', 'out.txt' -Text 'Placeholder'
    Write-RepoText -Part 'scripts', 'Define.psm1' -Text "'Placeholder'"
    Write-RepoText -Part 'empty.cs' -Text ''
    New-TestFolder -Path (Get-RepoPath '.git') | Out-Null
    [System.IO.File]::WriteAllBytes((Get-RepoPath 'Placeholder.png'),
        [byte[]]@(0x89, 0x50, 0x4E, 0x47) + [System.Text.Encoding]::ASCII.GetBytes('Placeholder'))
    [System.IO.File]::WriteAllBytes((Get-RepoPath 'pkg.nupkg'), $nupkgBytes)
}

function Format-Hex {
    param([byte[]]$Bytes)

    return ($Bytes | ForEach-Object { $_.ToString('x2') }) -join ' '
}

Write-TestSection '1. the happy path'
# Arrange
New-Lab
$before = Get-ChangeCount

# Act
Rename-Token -RepoPath $repo -From 'Placeholder' -To 'MyProj'

# Assert
Assert-That 'renamed inside a repo under a folder named scripts' `
(Test-Path (Get-RepoPath 'src' 'MyProj' 'MyProj.cs')) 'the relative-path exclusion fix'
Assert-That 'content rewritten' ((Get-RepoText 'src' 'MyProj' 'MyProj.cs') -notmatch 'Placeholder')
Assert-That 'CRLF preserved' ((Get-RepoText 'src' 'MyProj' 'MyProj.cs').Contains("`r`n"))
Assert-That 'Add-Change recorded' ((Get-ChangeCount) -gt $before) `
    "before=$before after=$(Get-ChangeCount)"

$slnx = Get-RepoBytes 'MyRepo.slnx'
Assert-That 'UTF-8 BOM preserved' `
    ($slnx[0] -eq 0xEF -and $slnx[1] -eq 0xBB -and $slnx[2] -eq 0xBF) `
    "first bytes: $(Format-Hex $slnx[0..2])"
Assert-That 'BOM file content still rewritten' ((Get-RepoText 'MyRepo.slnx') -match 'MyProj')

$utf16 = Get-RepoBytes 'utf16.txt'
Assert-That 'UTF-16 not transcoded' ($utf16[0] -eq 0xFF -and $utf16[1] -eq 0xFE) `
    "first bytes: $(Format-Hex $utf16[0..1])"
Assert-That 'UTF-16 content rewritten' ((Get-RepoText 'utf16.txt') -match 'MyProj')

$nupkg = Get-RepoBytes 'pkg.nupkg'
Assert-That 'binary left byte-identical despite holding the token' `
(-not (Compare-Object $nupkg $nupkgBytes -SyncWindow 0)) `
    "length=$($nupkg.Length) expected=$($nupkgBytes.Length)"

Assert-That 'excluded bin/ content untouched' `
    ((Get-RepoText 'bin' 'Placeholder' 'out.txt') -eq 'Placeholder')
Assert-That 'excluded bin/ name untouched' (Test-Path (Get-RepoPath 'bin' 'Placeholder'))
Assert-That 'excluded scripts/ untouched' `
    ((Get-RepoText 'scripts' 'Define.psm1') -eq "'Placeholder'")
Assert-That 'skipped-extension file renamed but not rewritten' `
((Test-Path (Get-RepoPath 'MyProj.png')) -and
    ([System.Text.Encoding]::ASCII.GetString((Get-RepoBytes 'MyProj.png')) -match 'Placeholder'))
Assert-That 'empty file survived' ((Get-RepoText 'empty.cs') -eq '')

Write-TestSection '2. a second, identical run is a no-op'
# Arrange
New-Lab
Rename-Token -RepoPath $repo -From 'Placeholder' -To 'MyProj'
$before = Get-ChangeCount

# Act
Rename-Token -RepoPath $repo -From 'Placeholder' -To 'MyProj'

# Assert
Assert-That 'no change recorded on a no-op run' ((Get-ChangeCount) -eq $before) `
    "before=$before after=$(Get-ChangeCount)"

Write-TestSection '3. a case-only rename'
# Arrange
New-Lab
$before = Get-ChangeCount

# Act
Rename-Token -RepoPath $repo -From 'Placeholder' -To 'placeholder'

# Assert
Assert-That 'case-only rename is not skipped' ((Get-ChangeCount) -gt $before)
Assert-That 'case-only content rewritten' `
((Get-RepoText 'src' 'placeholder' 'placeholder.cs') -match 'namespace placeholder;')

Write-TestSection '4. genuinely nothing to do'
# Arrange
New-Lab
$before = Get-ChangeCount

# Act
Rename-Token -RepoPath $repo -From 'Absent' -To 'Whatever'

# Assert
Assert-That 'absent token records no change' ((Get-ChangeCount) -eq $before)

# Act
Rename-Token -RepoPath $repo -From 'Same' -To 'Same'

# Assert
Assert-That 'From equals To records no change' ((Get-ChangeCount) -eq $before)

Write-TestSection '5. errors name what the operator has to fix'
# Act + Assert
Assert-Throws 'missing folder throws, naming the path' -Match '(?=.*no such folder)(?=.*nope)' `
    { Rename-Token -RepoPath (Join-Path $root 'nope') -From 'A' -To 'B' }

# Arrange
New-Lab

# Act + Assert
# A '/' is illegal in a file name on every platform; ':' is legal on Linux.
Assert-Throws 'illegal target throws' -Match 'not a legal file name' `
    { Rename-Token -RepoPath $repo -From 'Placeholder' -To 'bad/name' }
Assert-That 'nothing was rewritten by the rejected run' `
((Get-RepoText 'src' 'Placeholder' 'Placeholder.cs') -match 'namespace Placeholder;')

Assert-Throws 'a target containing the source throws' -Match 'contains the old' `
    { Rename-Token -RepoPath $repo -From 'Placeholder' -To 'PlaceholderLib' }
Assert-That 'nothing was rewritten by that rejected run either' `
((Get-RepoText 'src' 'Placeholder' 'Placeholder.cs') -match 'namespace Placeholder;')

Write-TestSection '6. a rename collision is refused'
# Arrange
New-Lab
Write-RepoText -Part 'src', 'Taken.cs' -Text 'x'
Write-RepoText -Part 'src', 'Placeholder.cs' -Text 'y'

# Act + Assert
Assert-Throws 'collision names both source and target' `
    -Match '(?=.*Placeholder\.cs)(?=.*Taken\.cs)' `
    { Rename-Token -RepoPath $repo -From 'Placeholder' -To 'Taken' }

Write-TestSection '7. an unreadable file ends the run, named, after the rest is done'
# Arrange
New-Lab
$locked = Get-RepoPath 'src' 'Locked.cs'
Write-RepoText -Part 'src', 'Locked.cs' -Text 'Placeholder'
$hold = [System.IO.File]::Open($locked, 'Open', 'Read', 'None')

# Act
$lockedError = ''
try { Rename-Token -RepoPath $repo -From 'Placeholder' -To 'MyProj' }
catch { $lockedError = $_.Exception.Message }
finally { $hold.Dispose() }

# Assert
Assert-That 'a locked file throws, naming it and the count' `
($lockedError -match 'Locked\.cs' -and $lockedError -match '1 item') $lockedError
Assert-That 'the rest of the tree was still renamed first' `
(Test-Path (Get-RepoPath 'src' 'MyProj' 'MyProj.cs'))

Write-TestSection '8. the module surface'
$exported = (Get-Command -Module Common-Text).Name
foreach ($n in 'Rename-Token', 'Update-FileToken') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
