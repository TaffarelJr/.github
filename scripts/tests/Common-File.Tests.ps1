#Requires -Version 7.0
<#
    Tests for Common-File.psm1: reading a file's encoding and line ending back
    off the file, and writing it again with both intact.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-File'

$root = New-TestRoot -Name 'file'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$utf16Le = [System.Text.UnicodeEncoding]::new($false, $true)
$utf16Be = [System.Text.UnicodeEncoding]::new($true, $true)

function New-File {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [System.Text.Encoding]$Encoding = $utf8
    )

    $path = Join-Path $root $Name
    [System.IO.File]::WriteAllText($path, $Text, $Encoding)
    return $path
}

function Get-Text {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.File]::ReadAllText($Path)
}

function Get-Bytes {
    param([Parameter(Mandatory)][string]$Path)

    return , [System.IO.File]::ReadAllBytes($Path)
}

function Get-Preamble {
    param([Parameter(Mandatory)][string]$Path)

    return , (Get-FileEncoding -Path $Path).GetPreamble()
}

Write-TestSection '1. Get-FileEncoding reads the byte order mark'
# Arrange
$plain = New-File -Name 'plain.txt' -Text 'x'
$bom = New-File -Name 'bom.txt' -Text 'x' -Encoding $utf8Bom
$little = New-File -Name 'utf16le.txt' -Text 'x' -Encoding $utf16Le
$big = New-File -Name 'utf16be.txt' -Text 'x' -Encoding $utf16Be
$empty = New-File -Name 'empty.txt' -Text ''
$short = New-File -Name 'short.txt' -Text 'ab'

# Act + Assert
Assert-That 'no mark is UTF-8 without a BOM' `
    ((Get-FileEncoding -Path $plain) -is [System.Text.UTF8Encoding] -and
    (Get-Preamble $plain).Count -eq 0)
Assert-That 'EF BB BF is UTF-8 with a BOM' ((Get-Preamble $bom).Count -eq 3)
Assert-That 'FF FE is UTF-16 little-endian' `
    ((Get-FileEncoding -Path $little) -is [System.Text.UnicodeEncoding] -and
    (Get-Preamble $little)[0] -eq 0xFF)
Assert-That 'FE FF is UTF-16 big-endian' `
    ((Get-FileEncoding -Path $big) -is [System.Text.UnicodeEncoding] -and
    (Get-Preamble $big)[0] -eq 0xFE)
Assert-That 'an empty file is UTF-8 without a BOM' ((Get-Preamble $empty).Count -eq 0)
Assert-That 'a file shorter than a BOM is read without overrunning' `
    ((Get-Preamble $short).Count -eq 0)

Write-TestSection '2. Get-LineEnding reads the ending the text already uses'
# Act + Assert
Assert-Equal 'CRLF' -Expected "`r`n" -Actual (Get-LineEnding -Content "a`r`nb`r`n")
Assert-Equal 'LF' -Expected "`n" -Actual (Get-LineEnding -Content "a`nb`n")
Assert-Equal 'a mixed file counts as CRLF' -Expected "`r`n" `
    -Actual (Get-LineEnding -Content "a`nb`r`n")
Assert-Equal 'no ending at all falls back to this platform' -Expected ([Environment]::NewLine) `
    -Actual (Get-LineEnding -Content 'one line')
Assert-Equal 'and so does empty content' -Expected ([Environment]::NewLine) `
    -Actual (Get-LineEnding -Content '')

Write-TestSection '3. Read-TextFile returns all three together'
# Arrange
$path = New-File -Name 'read.txt' -Text "a`r`nb`r`n" -Encoding $utf8Bom

# Act
$file = Read-TextFile -Path $path

# Assert
Assert-Equal 'the content, without the BOM' -Expected "a`r`nb`r`n" -Actual $file.Content
Assert-That 'the encoding still carries the BOM' ($file.Encoding.GetPreamble().Length -eq 3)
Assert-Equal 'the line ending' -Expected "`r`n" -Actual $file.LineEnding

Write-TestSection '4. Write-TextFile -Lines joins with the file''s own ending, one trailing'
# Arrange
$path = New-File -Name 'lines.txt' -Text "old`nfile`n"

# Act
Write-TextFile -Path $path -Lines 'a', '', 'b'

# Assert
Assert-Equal 'joined with LF, blank line kept, exactly one trailing' -Expected "a`n`nb`n" `
    -Actual (Get-Text $path)
Assert-That 'no BOM was added' ((Get-Bytes $path)[0] -ne 0xEF)

# Arrange
$path = New-File -Name 'lines-crlf.txt' -Text "old`r`n"

# Act
Write-TextFile -Path $path -Lines 'a', 'b'

# Assert
Assert-Equal 'joined with CRLF when that is what the file had' -Expected "a`r`nb`r`n" `
    -Actual (Get-Text $path)

# Act
Write-TextFile -Path $path -Lines @()

# Assert
Assert-Equal 'no lines is one bare ending' -Expected "`r`n" -Actual (Get-Text $path)

Write-TestSection '5. Write-TextFile -Content writes exactly what it is given'
# Arrange
$path = New-File -Name 'content.txt' -Text "x`r`n" -Encoding $utf8Bom

# Act
Write-TextFile -Path $path -Content "new`r`ntext"

# Assert
Assert-Equal 'no ending is added' -Expected "new`r`ntext" -Actual (Get-Text $path)
Assert-That 'the BOM is kept' ((Get-Bytes $path)[0] -eq 0xEF)

# Act
Write-TextFile -Path $path -Content ''

# Assert
Assert-Equal 'empty content is allowed' -Expected '' -Actual (Get-Text $path)

Write-TestSection '6. a UTF-16 file stays UTF-16'
# Arrange
$path = New-File -Name 'roundtrip.txt' -Text "x`r`n" -Encoding $utf16Le

# Act
Write-TextFile -Path $path -Lines 'caf', 'é'

# Assert
$bytes = Get-Bytes $path
Assert-That 'the byte order mark survives' ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
Assert-Equal 'and the text decodes' -Expected "caf`r`né`r`n" -Actual (Get-Text $path)

Write-TestSection '7. -LikeFilePath supplies the encoding and ending only for a NEW file'
# Arrange
$sibling = New-File -Name 'sibling.txt' -Text "x`r`n" -Encoding $utf8Bom
$existing = New-File -Name 'existing.txt' -Text "x`n"

# Act
Write-TextFile -Path $existing -Lines 'a' -LikeFilePath $sibling

# Assert
Assert-Equal 'an existing file keeps its own ending' -Expected "a`n" -Actual (Get-Text $existing)
Assert-That 'and its own lack of a BOM' ((Get-Bytes $existing)[0] -ne 0xEF)

# Arrange
$fresh = Join-Path $root 'fresh.txt'

# Act
Write-TextFile -Path $fresh -Lines 'a' -LikeFilePath $sibling

# Assert
Assert-Equal 'a new file takes the sibling ending' -Expected "a`r`n" -Actual (Get-Text $fresh)
Assert-That 'and the sibling BOM' ((Get-Bytes $fresh)[0] -eq 0xEF)

# Arrange
$alone = Join-Path $root 'alone.txt'

# Act
Write-TextFile -Path $alone -Lines 'a' -LikeFilePath (Join-Path $root 'nowhere.txt')

# Assert
Assert-Equal 'with no sibling either, this platform''s ending' `
    -Expected "a$([Environment]::NewLine)" `
    -Actual (Get-Text $alone)
Assert-That 'and UTF-8 without a BOM' ((Get-Bytes $alone)[0] -eq [byte][char]'a')

Write-TestSection '8. the module surface'
$exported = (Get-Command -Module Common-File).Name
foreach ($n in 'Get-FileEncoding', 'Get-LineEnding', 'Read-TextFile', 'Write-TextFile') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
