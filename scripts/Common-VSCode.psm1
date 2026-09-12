#Requires -Version 7.0
<#
    The VS Code multi-root workspace file, and opening it.

    A workspace is generated rather than committed: it names the sibling
    clones of the template chain that happen to exist on this machine, so it
    is one developer's view of the chain and has no business travelling to
    another. It is written through Common-File and, being gitignored and new,
    takes this machine's own line ending - git never has a say in it.

    Windows-only in practice - it looks for Code.exe and the usual install
    locations - even though nothing here refuses to load elsewhere.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Constants
#───────────────────────────────────────────────────────────────────────────────

# Where each flavour of VS Code installs: the CLI shim on PATH, the exe it sits
# beside, and the usual install folders. Stable is tried before Insiders.
$script:VSCodeFlavours = @(
    @{ Cli = 'code'; Exe = 'Code.exe'; Folder = 'Microsoft VS Code' }
    @{ Cli = 'code-insiders'; Exe = 'Code - Insiders.exe'; Folder = 'Microsoft VS Code Insiders' }
)

# Build output and caches never hold the primary solution, and searching them
# is wasted work. Matched against the path RELATIVE to the repo - see
# Find-Solution for why.
$script:SolutionExcludePattern = '(^|[\\/])(bin|obj|node_modules|\.git)([\\/]|$)'

#───────────────────────────────────────────────────────────────────────────────
# Workspace file
#───────────────────────────────────────────────────────────────────────────────

function Get-NativePath {
    <#
    .SYNOPSIS
        Resolves a path to the filesystem path .NET and git will see.
    .DESCRIPTION
        Not exported. Resolve-Path's .Path is the PowerShell path, which under
        a mapped PSDrive reads 'Work:\MyRepo' - a prefix that shares nothing
        with a FileInfo's FullName, so comparing the two silently produces
        nonsense. .ProviderPath is the real one.
    #>
    param([Parameter(Mandatory)][string]$Path)
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Get-RelativePosixPath {
    <#
    .SYNOPSIS
        Returns the path from one location to another, forward slashes only.
    .DESCRIPTION
        Not exported. Both a workspace folder entry and dotnet.defaultSolution
        need exactly this, and a subtraction of string lengths is not it.
    #>
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    return ([System.IO.Path]::GetRelativePath($From, $To) -replace '\\', '/')
}

function Get-FolderSettingsBlock {
    <#
    .SYNOPSIS
        Returns .vscode/settings.json's body,
        re-indented for a .code-workspace 'settings' block.
    .DESCRIPTION
        Not exported. VS Code ignores window-scoped settings coming from
        folder settings while a multi-root workspace is open, so they have to
        be restated in the workspace file. Resource-scoped ones still resolve
        from the folder that defines them, which outranks this copy, so
        mirroring the whole file is safe and avoids hard-coding which keys are
        window-scoped.

        Only folders[0]'s settings are mirrored; an ancestor's own are left to
        resolve from the ancestor. Spliced as text, not parsed, so key order
        and comments inside the object survive.
    #>
    param([Parameter(Mandatory)][string]$RepoFullPath)

    $path = Join-Path $RepoFullPath '.vscode' 'settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    # Taken between the outermost braces rather than assuming the file starts
    # with one: settings.json is JSONC, so a leading or trailing // note is
    # legal and must not read as 'not an object'.
    $text = (Get-Content -LiteralPath $path -Raw).Trim()
    $open = $text.IndexOf('{')
    $close = $text.LastIndexOf('}')
    if ($open -lt 0 -or $close -le $open) {
        Write-Warn "No JSON object found, so not mirrored: $path"
        return @()
    }

    $body = $text.Substring($open + 1, $close - $open - 1)
    $lines = @($body -split '\r?\n' | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return @() }

    # Whitespace, not spaces: a tab-indented file would otherwise measure as
    # zero and keep its tabs on top of the shift applied below.
    $strip = ($lines |
        ForEach-Object { $_.Length - $_.TrimStart(' ', "`t").Length } |
        Measure-Object -Minimum).Minimum

    # Both files indent JSON by two spaces, so the source lines keep their own
    # relative nesting and only need shifting one level deeper.
    return @($lines | ForEach-Object { '    ' + $_.Substring($strip) })
}

function Get-WorkspaceFolder {
    <#
    .SYNOPSIS
        Builds the workspace 'folders' entries: this repo, then its ancestors.
    .DESCRIPTION
        Not exported. The new repo is listed first, because tooling that is
        not multi-root aware only ever sees folders[0]. Ancestor paths are
        made relative to it, forward slashes only.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoFullPath,
        [Parameter(Mandatory)][string]$RepoName,
        [string[]]$ChainPaths = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('    // The new repo. Listed first so it is folders[0], the primary.')
    $lines.Add("    { `"name`": `"$RepoName`", `"path`": `".`" },")
    if ($ChainPaths.Count -eq 0) { return $lines }

    $lines.Add('    // Template layers inherited from, nearest parent first.')
    foreach ($path in $ChainPaths) {
        $name = Split-Path -Leaf $path
        $rel = Get-RelativePosixPath -From $RepoFullPath -To (Get-NativePath -Path $path)
        $lines.Add("    { `"name`": `"$name`", `"path`": `"$rel`" },")
    }

    return $lines
}

function Find-Solution {
    <#
    .SYNOPSIS
        Returns the repo's solution files, shallowest first,
        ignoring bin, obj, node_modules and .git.
    .DESCRIPTION
        Not exported. Depth-limited: a solution nested deeper than three
        levels is not the primary one, and walking a whole tree to establish
        that is wasted work. Ordered by how deep it sits rather than by name,
        because that is the same reasoning applied to the ones it did find.

        Warns about a subtree it could not read, so 'no solution' cannot come
        from a folder it never looked in.
    #>
    param([Parameter(Mandatory)][string]$RepoFullPath)

    $found = Get-ChildItem -LiteralPath $RepoFullPath -File -Recurse -Depth 3 `
        -Include *.sln, *.slnx, *.slnf `
        -ErrorAction SilentlyContinue -ErrorVariable failures
    foreach ($failure in $failures) {
        Write-Warn "Not searched for solutions: $($failure.TargetObject)"
    }

    # Relative to the repo, not absolute: a repo that merely lives under a
    # folder named 'bin' or 'obj' would otherwise discard every solution it
    # has and pin 'disable' instead. No leading comma on the return - the one
    # caller wraps this in @(), which is what keeps a single hit an array.
    $root = $RepoFullPath.TrimEnd('\', '/')
    return @($found |
        Where-Object {
            $_.FullName.Substring($root.Length) -notmatch $script:SolutionExcludePattern
        } |
        Sort-Object { ($_.FullName -split '[\\/]').Count }, FullName)
}

function Get-WorkspaceSetting {
    <#
    .SYNOPSIS
        Builds the workspace 'settings' entries.
    .DESCRIPTION
        Not exported. dotnet.defaultSolution is window-scoped, so it only
        takes effect here and is ignored per-folder. Pinning it stops C# Dev
        Kit adopting a template layer's placeholder solution, or prompting on
        every open when it finds several.
    #>
    param([Parameter(Mandatory)][string]$RepoFullPath)

    # @() around both calls, and not optional: PowerShell unrolls an empty
    # array returned from a function into nothing, so a repo with no solution
    # or no .vscode/settings.json would leave these $null and the .Count
    # checks below would throw under StrictMode.
    $solutions = @(Find-Solution -RepoFullPath $RepoFullPath)
    $mirrored = @(Get-FolderSettingsBlock -RepoFullPath $RepoFullPath)
    $comma = if ($mirrored.Count -gt 0) { ',' } else { '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($solutions.Count -gt 0) {
        $rel = Get-RelativePosixPath -From $RepoFullPath -To $solutions[0].FullName
        if ($solutions.Count -gt 1) {
            $lines.Add("    // $($solutions.Count) solutions found; pinned the shallowest.")
        }

        $lines.Add('    // Relative to folders[0]. Forward slashes required.')
        $lines.Add("    `"dotnet.defaultSolution`": `"$rel`"$comma")
    }
    else {
        $lines.Add("    // No solution yet. 'disable' stops C# Dev Kit from adopting")
        $lines.Add("    // a TEMPLATE layer's, and silences the 'open solution' nag.")
        $lines.Add("    // Replace with e.g. `"MyRepo.sln`" once you add one.")
        $lines.Add("    `"dotnet.defaultSolution`": `"disable`"$comma")
    }

    if ($mirrored.Count -gt 0) {
        $lines.Add('')
        $lines.Add('    // Mirrored from .vscode/settings.json, because VS Code ignores')
        $lines.Add('    // window-scoped folder settings in a multi-root workspace.')
        $lines.AddRange([string[]]$mirrored)
    }

    return $lines
}

function Get-WorkspaceContent {
    <#
    .SYNOPSIS
        Builds the whole .code-workspace, line by line.
    .DESCRIPTION
        Not exported. JSONC, not JSON: the comments are for the next reader,
        which is why this is assembled as text rather than via ConvertTo-Json.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoFullPath,
        [Parameter(Mandatory)][string]$RepoName,
        [string[]]$ChainPaths = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(
            '{'
            "  // Multi-root workspace for $RepoName and its template layers."
            '  // Generated by the scaffolding scripts; local-only.'
            '  // Safe to edit or delete - only a -Force re-run rewrites it.'
            "  `"folders`": ["
        ))

    $folders = Get-WorkspaceFolder -RepoFullPath $RepoFullPath -RepoName $RepoName `
        -ChainPaths $ChainPaths
    $lines.AddRange([string[]]@($folders))
    $lines.AddRange([string[]]@('  ],', "  `"settings`": {"))
    $lines.AddRange([string[]]@(Get-WorkspaceSetting -RepoFullPath $RepoFullPath))
    $lines.AddRange([string[]]@('  }', '}'))
    return $lines
}

function Write-WorkspaceFile {
    <#
    .SYNOPSIS
        Writes a multi-root <repo>.code-workspace,
        spanning the new repo and its template chain.
    .DESCRIPTION
        Paths resolve against this file's own folder, so the new repo is "."
        and each ancestor is relative to it - "../<name>" for the sibling
        clones Get-TemplateChain returns, and whatever else fits for anything
        further afield.
    .PARAMETER ChainPaths
        Ancestor template paths, nearest first. Each has to exist.
    .PARAMETER Force
        Overwrites an existing workspace file, instead of leaving edits alone.
        For the case where the pinned solution has gone stale - the repo had
        none when the file was written, so it says 'disable' and will keep
        saying it.
    .OUTPUTS
        [string] - the workspace file's path, written or not.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$RepoName,
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string[]]$ChainPaths = @(),
        [switch]$Force
    )

    $repoFull = Get-NativePath -Path $RepoPath
    $wsPath = Join-Path $repoFull "$RepoName.code-workspace"
    Write-Doing "Writing $RepoName.code-workspace"
    if ((Test-Path -LiteralPath $wsPath) -and -not $Force) {
        Write-Done -Skip 'already exists, left alone'
        return $wsPath
    }

    $lines = Get-WorkspaceContent -RepoFullPath $repoFull -RepoName $RepoName `
        -ChainPaths $ChainPaths
    Write-TextFile -Path $wsPath -Lines ([string[]]@($lines))
    Add-Change
    Write-Done "$(1 + $ChainPaths.Count) folder(s)"
    return $wsPath
}

#───────────────────────────────────────────────────────────────────────────────
# Launching
#───────────────────────────────────────────────────────────────────────────────

function Get-VSCodeCandidate {
    <#
    .SYNOPSIS
        Returns every path one flavour of VS Code might be installed at, most
        specific first.
    .DESCRIPTION
        Not exported. The exe derived from the CLI shim on PATH, then the shim
        itself, then the usual install folders. Code.exe is preferred over the
        code.cmd shim because launching a .cmd through Start-Process flashes a
        console window, while the exe returns immediately and cleanly. The shim
        is still worth having: a leftover one from a moved install fails the
        caller's existence test and simply does not become a candidate.
    #>
    param([Parameter(Mandatory)][hashtable]$Flavour)

    $candidates = [System.Collections.Generic.List[string]]::new()

    # Application only. An alias or a function named 'code' is a perfectly
    # ordinary thing to have, and its .Source is a module name or empty - on
    # which every path operation below fails.
    $cli = @(Get-Command $Flavour.Cli -CommandType Application -ErrorAction SilentlyContinue)
    if ($cli.Count -gt 0 -and $cli[0].Source) {
        # <root>\bin\code.cmd -> <root>\Code.exe
        $root = Split-Path -Parent (Split-Path -Parent $cli[0].Source)
        if ($root) { $candidates.Add((Join-Path $root $Flavour.Exe)) }
        $candidates.Add($cli[0].Source)
    }

    # Guarded one at a time, because Join-Path rejects an empty path and
    # ProgramFiles(x86) does not exist on every machine.
    $bases = [System.Collections.Generic.List[string]]::new()
    if ($env:LOCALAPPDATA) { $bases.Add((Join-Path $env:LOCALAPPDATA 'Programs')) }
    if ($env:ProgramFiles) { $bases.Add($env:ProgramFiles) }
    if (${env:ProgramFiles(x86)}) { $bases.Add(${env:ProgramFiles(x86)}) }
    foreach ($base in $bases) { $candidates.Add((Join-Path $base $Flavour.Folder $Flavour.Exe)) }

    return $candidates
}

function Get-VSCodeExecutable {
    <#
    .SYNOPSIS
        Returns the VS Code executable to launch, or $null if none is found.
    .DESCRIPTION
        Not exported. Stable before Insiders and, within a flavour, in the
        order Get-VSCodeCandidate lists them.
    #>
    foreach ($flavour in $script:VSCodeFlavours) {
        foreach ($candidate in Get-VSCodeCandidate -Flavour $flavour) {
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    return $null
}

function Get-VSCodeArgument {
    <#
    .SYNOPSIS
        Builds the argument list for launching VS Code.
    .DESCRIPTION
        Not exported. Split out from Start-VSCode so the two-path case - a
        workspace plus a file to focus - is unit-testable without launching
        a process. A blank ActiveFile is omitted rather than passed through,
        so the caller does not have to know that itself.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$ActiveFile
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add($Target)
    if ($ActiveFile) { $arguments.Add($ActiveFile) }
    return , @($arguments.ToArray())
}

function Start-VSCode {
    <#
    .SYNOPSIS
        Opens a path in VS Code as a separate, detached process.
    .DESCRIPTION
        The path can be a folder or a .code-workspace. Never throws - failing
        to open an editor should not fail a successful scaffold - so finding
        it is inside the same guard as launching it.
    .PARAMETER ActiveFile
        A file to also open, as the focused tab - the end-of-run checklist,
        say. Omitted when there is nothing to focus.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Target,
        [string]$ActiveFile
    )

    Write-Doing "Opening $(Split-Path -Leaf $Target) in VS Code"
    try {
        $exe = Get-VSCodeExecutable
        if (-not $exe) {
            Write-Warn "VS Code not found - open it yourself: $Target"
            return
        }

        $arguments = Get-VSCodeArgument -Target $Target -ActiveFile $ActiveFile
        Start-Process -FilePath $exe -ArgumentList $arguments | Out-Null
        Write-Done
    }
    catch {
        Write-Warn "Couldn't launch VS Code ($($_.Exception.Message)) - open it yourself: $Target"
    }
}

Export-ModuleMember -Function @(
    'Write-WorkspaceFile'
    'Start-VSCode'
)
