#Requires -Version 7.0
<#
    Reading and writing a text file without disturbing what it already is.

    A file's encoding and line ending are properties of the file, not of
    whoever last edited it - so a rewrite has to read them back off the file
    first and reuse them, or it silently drifts the file toward whatever this
    process's own defaults happen to be. That matters most across platforms:
    a checkout normalises most files to the OS's own line ending, and a
    handful (this repo's PowerShell scripts among them) are pinned to one
    line ending by .gitattributes regardless of OS. Either way, the file on
    disk already says which - there is nothing here to detect the platform.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Reading
#───────────────────────────────────────────────────────────────────────────────

function Get-FileEncoding {
    <#
    .SYNOPSIS
        Returns the encoding a file is written in, from the byte order mark
        it currently starts with.
    .DESCRIPTION
        Rewriting a file through PowerShell's own defaults is lossy:
        Set-Content writes UTF-8 without a BOM, so a file that had one loses
        it and a UTF-16 file is silently transcoded. Reading the mark and
        handing it back keeps a content edit to just the content.

        UTF-8 without a BOM is the fallback, which is also what .NET assumes
        when it decodes.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $bom = [byte[]]::new(3)
    $stream = [System.IO.File]::OpenRead($Path)
    try { $read = $stream.Read($bom, 0, 3) } finally { $stream.Dispose() }

    if ($read -ge 3 -and $bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF) {
        return [System.Text.UTF8Encoding]::new($true)
    }

    if ($read -ge 2 -and $bom[0] -eq 0xFF -and $bom[1] -eq 0xFE) {
        return [System.Text.UnicodeEncoding]::new($false, $true)
    }

    if ($read -ge 2 -and $bom[0] -eq 0xFE -and $bom[1] -eq 0xFF) {
        return [System.Text.UnicodeEncoding]::new($true, $true)
    }

    return [System.Text.UTF8Encoding]::new($false)
}

function Get-LineEnding {
    <#
    .SYNOPSIS
        Returns the line ending already used in a piece of text.
    .DESCRIPTION
        Checked in this order because a CRLF file also matches a bare LF
        search - every "`n" is preceded by a "`r" in one, and isn't in the
        other. Falls back to this process's own default only for content
        that carries no line ending to read at all, such as a brand new file.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    if ($Content.Contains("`r`n")) { return "`r`n" }
    if ($Content.Contains("`n")) { return "`n" }
    return [Environment]::NewLine
}

function Read-TextFile {
    <#
    .SYNOPSIS
        Reads a text file's content, encoding, and line ending, so a
        rewrite can preserve all three.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $content = [System.IO.File]::ReadAllText($Path)
    return [pscustomobject]@{
        Content    = $content
        Encoding   = Get-FileEncoding -Path $Path
        LineEnding = Get-LineEnding -Content $content
    }
}

#───────────────────────────────────────────────────────────────────────────────
# Writing
#───────────────────────────────────────────────────────────────────────────────

function Write-TextFile {
    <#
    .SYNOPSIS
        Writes text back with the encoding and line ending it already had.
    .DESCRIPTION
        -LikeFilePath supplies both when Path does not exist yet: a file this
        repo is only now creating, that should still come out looking like a
        sibling already on disk. Falls back to UTF-8 without a BOM and this
        process's own line ending only when neither Path nor LikeFilePath
        exists - there being nothing on disk yet to match.
    .PARAMETER Lines
        Joined with the resolved line ending and given exactly one trailing
        one. Use this, not -Content, for anything built up a line at a time.
    .PARAMETER Content
        Written exactly as given. For the rarer case where the caller has
        already assembled the whole file, trailing line ending included.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Lines')]
        [AllowEmptyCollection()][AllowEmptyString()]
        [string[]]$Lines,
        [Parameter(Mandatory, ParameterSetName = 'Content')]
        [AllowEmptyString()]
        [string]$Content,
        [string]$LikeFilePath
    )

    $reference = if (Test-Path -LiteralPath $Path) {
        $Path
    }
    elseif ($LikeFilePath -and (Test-Path -LiteralPath $LikeFilePath)) {
        $LikeFilePath
    }
    else {
        $null
    }

    $encoding = if ($reference) { Get-FileEncoding -Path $reference }
    else { [System.Text.UTF8Encoding]::new($false) }

    $eol = if ($reference) {
        Get-LineEnding -Content ([System.IO.File]::ReadAllText($reference))
    }
    else {
        [Environment]::NewLine
    }

    $body = if ($PSCmdlet.ParameterSetName -eq 'Lines') { ($Lines -join $eol) + $eol }
    else { $Content }

    [System.IO.File]::WriteAllText($Path, $body, $encoding)
}

Export-ModuleMember -Function @(
    'Get-FileEncoding'
    'Get-LineEnding'
    'Read-TextFile'
    'Write-TextFile'
)
