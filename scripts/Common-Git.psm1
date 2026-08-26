#Requires -Version 7.0
<#
    Local git operations: cloning, remotes, staging, committing, pushing.

    Invoke-GatedCommit gates a group on its own commit subject, so a step
    that already ran is skipped rather than repeated. That is what makes a
    re-run safe, and the gate reads only commits this repo added on top of
    its template, so an inherited history cannot satisfy it.

    A group without a pathspec also records, under .git/, what was already
    dirty before its FIRST attempt - so one that crashed half-way is resumed
    rather than repeated, commits the whole of its work, and still leaves the
    developer's own in-flight edits alone.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Constants
#───────────────────────────────────────────────────────────────────────────────

# Both the branch this works on and the template branch it tracks. They are
# the same name by design: a repo derived from a template starts as that
# template's default branch.
$script:DefaultBranch = 'main'

# Every subject a gated group has finished under in this run. A repeat is a
# bug, not a resume: the second group's gate would read the first's commit as
# its own and skip it silently. Module state, so the entry script's -Force
# import starts every run clean.
$script:SeenSubjects = [System.Collections.Generic.HashSet[string]]::new()

function Get-DefaultBranch {
    <#
    .SYNOPSIS
        Returns the branch this scaffolding works on, and tracks in a template.
    #>
    return $script:DefaultBranch
}

#───────────────────────────────────────────────────────────────────────────────
# Running git
#───────────────────────────────────────────────────────────────────────────────

function Invoke-Git {
    <#
    .SYNOPSIS
        Runs git with its output captured, and throws if it fails.
    .DESCRIPTION
        Only for calls where a non-zero exit is genuinely an error. The two
        other kinds have their own wrapper: Test-GitSucceeds for a call that
        USES the exit code as its answer, and Read-GitOutput for one read
        purely for its output, where nothing at all is a legitimate answer.
    .PARAMETER RepoPath
        The repo to run in, passed as git's -C so no directory is changed.
    .PARAMETER Arguments
        Must be an explicit array. Loose tokens bind as PowerShell parameters
        instead of git arguments, without any error.
    .OUTPUTS
        The command's output lines, ALWAYS as an array - Invoke-NativeCommand
        returns it with a leading comma so one line does not unroll to a
        scalar. That cuts both ways: never wrap a call to this in @(), which
        would nest that array inside another and break every -contains, -in
        and .Count on the result.
    #>
    param(
        [Parameter(Mandatory)][string]$Activity,
        [string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    # [string[]] on the local matters. An if-expression unwraps a one-element
    # array to a scalar, and splatting a string passes it one CHARACTER at a
    # time - so a single-argument call with no -RepoPath would run 'git v e r'.
    [string[]]$argv = if ($RepoPath) {
        @('-C', $RepoPath) + $Arguments
    }
    else { $Arguments }

    return Invoke-NativeCommand -Activity $Activity -Command 'git' -Arguments $argv
}

function Test-GitSucceeds {
    <#
    .SYNOPSIS
        Runs a git command for its exit code alone, and returns whether it was
        zero.
    .DESCRIPTION
        Not exported. For the calls that USE a non-zero exit as an answer -
        show-ref --quiet, rev-parse --verify, diff --cached --quiet, ls-files
        --error-unmatch. The output is discarded; Invoke-NativeRead resets the
        exit code, so a later check does not see a phantom failure.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $read = Invoke-NativeRead -Command 'git' -Arguments (@('-C', $RepoPath) + $Arguments)
    return $read.Ok
}

function Read-GitOutput {
    <#
    .SYNOPSIS
        Runs a git command purely for its output, where nothing at all is a
        legitimate answer.
    .DESCRIPTION
        Not exported. For git remote, rev-parse --abbrev-ref, diff
        --name-status and the like: a failure here means "nothing", not an
        error, so it reads as an empty result. Through Invoke-NativeRead, so
        the output is decoded as UTF-8 like every other read and the exit code
        is reset.
    .OUTPUTS
        Always an array, possibly empty - the leading comma on the return keeps
        it one. Do not wrap a call to this in @(), which would nest it.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $read = Invoke-NativeRead -Command 'git' -Arguments (@('-C', $RepoPath) + $Arguments)
    if (-not $read.Ok) { return , @() }
    return , $read.Output
}

#───────────────────────────────────────────────────────────────────────────────
# Clone & remotes
#───────────────────────────────────────────────────────────────────────────────

function Initialize-LocalRepo {
    <#
    .SYNOPSIS
        Ensures the push default, the 'template' remote, a fetch of it, the
        commit template, and that the working branch exists and is checked out.
    .DESCRIPTION
        Every write here is idempotent, and the branch is created from the
        template ONLY if it does not already exist, so resuming never resets
        existing history.

        The fetch is not idempotent in effect: it advances template/<branch>,
        which is the far end of the range Test-CommitSubject reads. A template
        that has since gained one of this repo's subjects moves it out of that
        range, and the step gated on it runs again.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$TemplateUrl
    )

    $branch = $script:DefaultBranch
    Write-Doing "Wiring the clone to its template"
    Invoke-Git -Activity 'Setting the push default' -RepoPath $RepoPath `
        -Arguments @('config', 'remote.pushdefault', 'origin') | Out-Null

    $remotes = Read-GitOutput -RepoPath $RepoPath -Arguments @('remote')
    if ($remotes -notcontains 'template') {
        Invoke-Git -Activity "Adding the 'template' remote" -RepoPath $RepoPath `
            -Arguments @('remote', 'add', 'template', $TemplateUrl) | Out-Null
    }
    else {
        Invoke-Git -Activity "Repointing the 'template' remote" -RepoPath $RepoPath `
            -Arguments @('remote', 'set-url', 'template', $TemplateUrl) | Out-Null
    }

    Invoke-Git -Activity 'Fetching the template remote' -RepoPath $RepoPath `
        -Arguments @('fetch', 'template') | Out-Null
    Invoke-Git -Activity 'Setting the commit template' -RepoPath $RepoPath `
        -Arguments @('config', 'commit.template', '.gitmessage') | Out-Null

    $branchExists = Test-GitSucceeds -RepoPath $RepoPath `
        -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch")
    if (-not $branchExists) {
        $templateRef = "template/$branch"
        Invoke-Git -Activity "Creating $branch from $templateRef" -RepoPath $RepoPath `
            -Arguments @('checkout', '-B', $branch, $templateRef) | Out-Null
        Write-Done "'template' -> $TemplateUrl, $branch created from $templateRef"
        return
    }

    $current = Read-GitOutput -RepoPath $RepoPath -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    if (($current -join '') -ne $branch) {
        Invoke-Git -Activity "Switching to $branch" -RepoPath $RepoPath `
            -Arguments @('checkout', $branch) | Out-Null
    }

    Write-Done "'template' -> $TemplateUrl, on $branch"
}

function Initialize-Clone {
    <#
    .SYNOPSIS
        Clones the new repo next to the template,
        or reuses an existing local clone.
    #>
    param(
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$OriginUrl,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$TargetPath,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$TemplateUrl
    )

    Write-Doing "Cloning $OriginUrl"
    if (Test-Path -LiteralPath $TargetPath) {
        if (-not (Test-Path -LiteralPath (Join-Path $TargetPath '.git'))) {
            throw ("Path exists but is not a git repo: $TargetPath " +
                '(remove it and retry).')
        }

        Write-Done -Skip 'already present, reusing without reset'
    }
    else {
        # git clone (not `gh repo clone`) keeps the URL's host alias/creds.
        Invoke-Git -Activity "Cloning $OriginUrl" `
            -Arguments @('clone', $OriginUrl, $TargetPath) | Out-Null
        Add-Change
        Write-Done "-> $TargetPath"
    }

    Initialize-LocalRepo -RepoPath $TargetPath -TemplateUrl $TemplateUrl
}

function Get-RemoteUrl {
    <#
    .SYNOPSIS
        Returns the URL of a named remote, or $null when the repo has no such
        remote.
    .DESCRIPTION
        $null rather than a throw, because a missing remote is a legitimate
        answer: the base of a template chain has no 'template' remote, and
        that is how a chain walk knows it has reached the top.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Name
    )

    $url = (Read-GitOutput -RepoPath $RepoPath -Arguments @('remote', 'get-url', $Name)) -join ''
    if (-not $url.Trim()) { return $null }
    return $url.Trim()
}

#───────────────────────────────────────────────────────────────────────────────
# Working tree
#───────────────────────────────────────────────────────────────────────────────

function Get-DirtyPath {
    <#
    .SYNOPSIS
        Returns the paths git currently reports as changed, one per entry.
    .DESCRIPTION
        Not exported. Read NUL-separated, because git's default porcelain
        output quotes and C-escapes any path holding a space or a non-ASCII
        character: 'café.txt' arrives as 'caf\303\251.txt', which names no
        file on disk, so the pathspec silently misses it and the change is
        never committed. -z emits the bytes as they are.

        A rename arrives as two entries, the new path and then the old. BOTH
        are returned, because staging only the new one would leave the
        deletion of the old out of the commit.

        Untracked files are listed one by one (-uall) rather than folded into
        their directory, so an untracked folder that was already there cannot
        hide a file the body later adds inside it.
    #>
    param([Parameter(Mandatory)][string]$RepoPath)

    $out = Invoke-Git -Activity 'Reading the working tree' -RepoPath $RepoPath `
        -Arguments @('status', '--porcelain', '-z', '-uall')
    $entries = @(($out -join '') -split "`0" | Where-Object { $_.Trim() })

    $paths = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = $entries[$i]
        if ($entry.Length -le 3) { continue }
        $paths.Add($entry.Substring(3))

        # A rename or copy puts the original path in the NEXT entry, which
        # carries no status prefix of its own.
        if ($entry.Substring(0, 2) -match '[RC]') {
            $i++
            if ($i -lt $entries.Count) { $paths.Add($entries[$i]) }
        }
    }

    return @($paths)
}

#───────────────────────────────────────────────────────────────────────────────
# Gate markers
#───────────────────────────────────────────────────────────────────────────────

function Get-GateMarkerPath {
    <#
    .SYNOPSIS
        Returns where a gated group's pre-attempt snapshot lives.
    .DESCRIPTION
        Not exported. Under the git directory, so it can never be staged,
        pushed, or synced to a descendant, and git status and git clean both
        leave it alone. Located by asking git rather than assuming '.git',
        since a clone's git directory can be a file pointing elsewhere.

        Named by a hash of the subject, which holds characters a file name
        cannot.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message
    )

    $gitDir = (Invoke-Git -Activity 'Locating the git directory' -RepoPath $RepoPath `
            -Arguments @('rev-parse', '--absolute-git-dir')) -join ''
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Message)) }
    finally { $sha.Dispose() }
    $key = [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 16)
    return Join-Path $gitDir 'new-repo-gate' "$key.json"
}

function Read-GateMarker {
    <#
    .SYNOPSIS
        Returns the snapshot an earlier attempt left, or $null if there is none.
    .DESCRIPTION
        Not exported. The file is what Write-GateMarker wrote: Subject, Started,
        and Before - the paths that were already dirty on the first attempt.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-GateMarker {
    <#
    .SYNOPSIS
        Records what was already dirty before a group's first attempt.
    .DESCRIPTION
        Not exported. UTF-8 without a BOM, explicitly: the paths arrived as raw
        bytes through -z and have to round-trip the same way.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Before
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $marker = [ordered]@{
        Subject = $Message
        Started = (Get-Date).ToUniversalTime().ToString('u')
        Before  = @($Before)
    }

    $json = ConvertTo-Json $marker -Depth 3
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Remove-GateMarker {
    <#
    .SYNOPSIS
        Forgets a group's snapshot, once the group has finished either way.
    .DESCRIPTION
        Not exported. Called on a commit, on a no-op, and when the gate is
        already satisfied - a stale snapshot would otherwise attribute the
        current dirt to a long-finished attempt.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}

function Resolve-GateBaseline {
    <#
    .SYNOPSIS
        Returns the paths a group must leave alone: what was dirty before its
        first attempt.
    .DESCRIPTION
        Not exported. On a first attempt that is the current dirt, and it is
        written to the marker. On a resume it is read back from the marker,
        narrowed to what is still dirty - a path the developer has committed
        since is no longer theirs to protect - and everything else now dirty
        is named as the earlier attempt's work, about to be adopted.
    #>
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Dirty
    )

    $saved = Read-GateMarker -Path $Marker
    if ($null -eq $saved) {
        Write-GateMarker -Path $Marker -Message $Message -Before $Dirty
        if ($Dirty) {
            Write-Warn ("$($Dirty.Count) path(s) were already modified before " +
                "'$Message' ran, and are left out of it")
            foreach ($path in $Dirty) { Write-Detail $path }
            Write-Detail 'they stay yours to commit - so does anything this group changed in them'
        }

        return , @($Dirty)
    }

    # @() around the property: ConvertFrom-Json unwraps a one-element array.
    $before = @(@($saved.Before) | Where-Object { $_ -in $Dirty })
    $adopted = @($Dirty | Where-Object { $_ -notin $before })
    Write-Warn "Resuming '$Message', interrupted $($saved.Started)"
    if ($adopted) {
        Write-Detail ("$($adopted.Count) path(s) that attempt left uncommitted " +
            "are going into this group's commit:")
        foreach ($path in $adopted) { Write-Detail "  $path" }
        Write-Detail 'if any of those is your own work, stop now and commit it first'
    }

    return , @($before)
}

#───────────────────────────────────────────────────────────────────────────────
# Commit & push
#───────────────────────────────────────────────────────────────────────────────

function Test-CommitSubject {
    <#
    .SYNOPSIS
        Returns true if THIS repo already made a commit with this exact
        subject, matched case-sensitively.
    .DESCRIPTION
        Not exported. Scoped to template/<branch>..HEAD: searching all history
        would match the same commits inherited from an already-scaffolded
        parent, and skip customizing the new repo entirely. Returns false when
        the template ref is missing, so the step re-runs harmlessly.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Message
    )

    # No template ref yet means nothing could have been gated, not a failure.
    $ref = "template/$($script:DefaultBranch)"
    $hasTemplate = Test-GitSucceeds -RepoPath $RepoPath `
        -Arguments @('rev-parse', '--verify', '--quiet', $ref)
    if (-not $hasTemplate) { return $false }

    $subjects = Invoke-Git -Activity 'Reading this repo''s commit subjects' `
        -RepoPath $RepoPath -Arguments @('log', '--format=%s', "$ref..HEAD")

    # -ceq over an array filters it, so this is an exact, case-sensitive match
    # on a whole subject: no group's message can satisfy another's gate by
    # prefix, and rewording one only in case unscaffolds the repo. A reverted
    # step still reads as done, since the original subject stays in the range.
    return [bool](@($subjects) -ceq $Message)
}

function Invoke-StagedCommit {
    <#
    .SYNOPSIS
        Stages the paths this group owns and commits,
        but only if something in them is actually staged.
    .DESCRIPTION
        Not exported; reached through Invoke-GatedCommit.

        Staging is scoped to -Paths, which is the safety boundary. Staging
        everything ('git add -A' with no pathspec) is unsafe on a re-run: if a
        group legitimately produces no diff, because the parent template
        already did that work, then no commit is made, its gate stays false,
        and the group runs again on every future run - sweeping a developer's
        unrelated uncommitted work into a 'chore:' commit. Scoping the
        pathspec makes an ungated no-diff group harmless.

        The commit itself is not scoped - see the comment below for why - so
        anything already staged elsewhere goes in with it.
    .PARAMETER Paths
        Pathspec to stage, relative to the repo. Required: there is no safe
        default, since the only obvious one ('.') is the whole tree.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Message,
        [Parameter(Mandatory)][string[]]$Paths
    )

    # 'git add -- <path>' is a hard error when the path is neither on disk nor
    # tracked, so drop those first - e.g. scripts/ in a template repo, which
    # is untouched.
    $spec = @($Paths | Where-Object {
            if (Test-Path -LiteralPath (Join-Path $RepoPath $_)) { return $true }
            Test-GitSucceeds -RepoPath $RepoPath `
                -Arguments @('ls-files', '--error-unmatch', '--', $_)
        })

    if (-not $spec) { Write-Skip "Nothing to stage for: $Message"; return }

    Invoke-Git -Activity 'Staging changes' -RepoPath $RepoPath `
        -Arguments (@('add', '-A', '--') + $spec) | Out-Null

    $nothingStaged = Test-GitSucceeds -RepoPath $RepoPath `
        -Arguments (@('diff', '--cached', '--quiet', '--') + $spec)
    if ($nothingStaged) { Write-Skip "Nothing to commit for: $Message"; return }

    # Summarise what is going in BEFORE committing, so the log shows the
    # grouping. Unscoped, to match the commit below rather than the pathspec:
    # if something else was already staged, it is going in too and the
    # operator should see it here.
    $staged = Read-GitOutput -RepoPath $RepoPath -Arguments @('diff', '--cached', '--name-status')

    # No pathspec on the commit, deliberately. Scoping it would drop the
    # deletion half of an already-staged rename: 'git mv' takes the old path
    # out of the index, so the prune above discards it and the commit would
    # record the new file without removing the old one. The cost is that
    # anything the developer had already staged elsewhere joins this commit.
    Write-Doing "Committing '$Message'"
    Invoke-Git -Activity "Committing '$Message'" -RepoPath $RepoPath `
        -Arguments @('commit', '-m', $Message) | Out-Null
    Add-Change
    Write-Done "$($staged.Count) file(s)"
    foreach ($line in $staged) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2) {
            Write-Detail ('{0}  {1}' -f $parts[0].PadRight(2), $parts[1])
        }
    }
}

function Invoke-GatedCommit {
    <#
    .SYNOPSIS
        Runs a group of related changes and commits them,
        unless that commit already exists.
    .DESCRIPTION
        $Message is both the commit subject and the idempotency key, so
        rewording one silently makes an already-scaffolded repo look
        unscaffolded. It also has to be unique within a run: a second group
        under the same subject would read the first's commit as its own and be
        skipped, so that throws instead.
    .PARAMETER Paths
        Pathspec to stage. Everything matching it is staged, including the
        developer's own edits to those same paths - a pathspec scopes what is
        staged, it does not separate authorship. Omit it to stage exactly what
        -Body dirtied, which is what you want for anything repo-wide. That is
        remembered across attempts: a group that crashed half-way commits the
        whole of its work when it is resumed, not just the rest.

        Either way, work merely MODIFIED outside the pathspec - or, without
        one, before the group's first attempt - is left alone; work already
        git-added anywhere is committed along with this group.
    .PARAMETER Body
        Scriptblock; it still sees the calling script's variables.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [Parameter(Mandatory)][ValidatePattern('\S')][string]$Message,
        [string[]]$Paths,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    if ($script:SeenSubjects.Contains($Message)) {
        throw ("'$Message' already gated a group in this run. Every group needs " +
            "its own subject: a second one reads the first's commit as its own " +
            'and is skipped.')
    }

    Invoke-GatedGroup -RepoPath $RepoPath -Message $Message -Paths $Paths -Body $Body

    # Recorded only once the group finished, so an attempt that threw can be
    # tried again in the same session - that is a resume, not a collision.
    [void]$script:SeenSubjects.Add($Message)
}

function Invoke-GatedGroup {
    <#
    .SYNOPSIS
        Runs one gated group: checks the gate, runs the body, commits.
    .DESCRIPTION
        Not exported; reached through Invoke-GatedCommit, which owns the
        one-subject-per-run rule and documents the parameters.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Paths,
        [Parameter(Mandatory)][scriptblock]$Body
    )

    $marker = Get-GateMarkerPath -RepoPath $RepoPath -Message $Message
    if (Test-CommitSubject -RepoPath $RepoPath -Message $Message) {
        # A snapshot left by an attempt that then finished - or was finished by
        # hand - would otherwise attribute today's dirt to it, the next time the
        # template fetch moves this subject back out of the gate's range.
        Remove-GateMarker -Path $marker
        Write-Skip "'$Message' already in history"
        return
    }

    if ($Paths) {
        & $Body
        Invoke-StagedCommit -RepoPath $RepoPath -Message $Message -Paths $Paths
        return
    }

    # No -Paths: stage exactly what the body dirtied - across ATTEMPTS, not
    # just this one. A hand-maintained list would silently omit files that a
    # repo-wide rename moved.
    #
    # The snapshot goes to disk before the body runs, because the body can
    # crash half-done. On the next run that half-done work is already dirty,
    # so a snapshot taken then would read it as the developer's and leave it
    # out - committing only the remainder, satisfying the gate, and orphaning
    # the rest. Worse, the deletion half of a completed rename is left out
    # too, so the commit records the new path and keeps the old one.
    $dirty = @(Get-DirtyPath -RepoPath $RepoPath)
    $before = Resolve-GateBaseline -Marker $marker -Message $Message -Dirty $dirty

    & $Body

    $after = @(Get-DirtyPath -RepoPath $RepoPath)
    $touched = @($after | Where-Object { $_ -notin $before })
    if (-not $touched) {
        Remove-GateMarker -Path $marker
        Write-Skip "Nothing changed for: $Message"
        return
    }

    Invoke-StagedCommit -RepoPath $RepoPath -Message $Message -Paths $touched
    Remove-GateMarker -Path $marker
}

function Push-Repo {
    <#
    .SYNOPSIS
        Pushes the working branch, setting upstream.
    .DESCRIPTION
        Idempotent. Success is read from --porcelain's machine-readable flag
        rather than git's summary line, which is localised: '=' in the first
        column means the ref was already up to date.
    .OUTPUTS
        [bool] - whether anything was actually sent.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath
    )

    $branch = $script:DefaultBranch
    Write-Doing "Pushing $branch"
    $out = Invoke-Git -Activity "Pushing $branch" -RepoPath $RepoPath `
        -Arguments @('push', '--porcelain', '-u', 'origin', $branch)
    if (($out -join "`n") -match '(?m)^=\s') {
        Write-Done -Skip 'already up to date on the remote'
        return $false
    }

    Write-Done
    return $true
}

Export-ModuleMember -Function @(
    'Invoke-Git'
    'Get-DefaultBranch'
    'Get-RemoteUrl'
    'Initialize-LocalRepo'
    'Initialize-Clone'
    'Invoke-GatedCommit'
    'Push-Repo'
)
