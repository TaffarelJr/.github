#Requires -Version 7.0
<#
    Tests for Common-Git.psm1: gated commits, their crash-resume markers, and
    the plumbing under them - against real git repos, because nothing else
    can vouch for what git actually does.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'TestKit.psm1') -Force
Import-ScriptModule 'Common-Console', 'Common-Process', 'Common-File', 'Common-Text', 'Common-Git'
$gitModule = Get-Module Common-Git

$root = New-TestRoot -Name 'git'
$lab = Join-Path $root 'lab'
$bare = Join-Path $root 'origin.git'

function New-Lab {
    Remove-TestFolder -Path $lab
    Remove-TestFolder -Path $bare
    git init -q --bare $bare
    git init -q -b main $lab
    # A hashtable, not an array of pairs: a multi-line @() flattens each
    # line's own @('key', 'value') into the outer array instead of nesting
    # it, so $setting[0]/$setting[1] silently indexed into characters of
    # a lone string - every one of these five configs was a no-op. Never
    # caught locally because a developer machine already has a global
    # git identity; a CI runner has none, so the later commit throws.
    $settings = [ordered]@{
        'user.name'      = 'Lab'
        'user.email'     = 'lab@example.com'
        'commit.gpgsign' = 'false'
        'core.autocrlf'  = 'false'
        'core.safecrlf'  = 'false'
    }

    foreach ($key in $settings.Keys) {
        git -C $lab config $key $settings[$key]
        if ($LASTEXITCODE -ne 0) { throw "git config $key failed (exit $LASTEXITCODE)" }
    }

    Write-LabFile -Part 'README.md' -Text 'original'
    git -C $lab add -A
    git -C $lab commit -q -m 'init'
    git -C $lab remote add origin $bare
    git -C $lab remote add template $bare
    git -C $lab push -q -u origin main 2>&1 | Out-Null
    git -C $lab fetch -q template 2>&1 | Out-Null
}

function Get-LabPath {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Part)

    $path = $lab
    foreach ($segment in $Part) { $path = Join-Path $path $segment }
    return $path
}

function Write-LabFile {
    param([Parameter(Mandatory)][string[]]$Part, [Parameter(Mandatory)][string]$Text)

    $path = Get-LabPath @Part
    New-TestFolder -Path (Split-Path -Parent $path) | Out-Null
    Set-Content -LiteralPath $path -Value $Text -NoNewline
}

function New-PlaceholderLab {
    param([switch]$WithSquatter)

    New-Lab
    Write-LabFile -Part 'src', 'Placeholder', 'Placeholder.csproj' `
        -Text '<AssemblyName>Placeholder</AssemblyName>'
    Write-LabFile -Part 'src', 'Placeholder', 'Class1.cs' -Text 'namespace Placeholder {}'
    Write-LabFile -Part 'docs', 'Placeholder.md' -Text '# Placeholder'
    Write-LabFile -Part 'README.md' -Text '# Placeholder readme'
    if ($WithSquatter) { Write-LabFile -Part 'docs', 'MyProj.md' -Text 'squatter' }
    git -C $lab add -A
    git -C $lab commit -q -m 'placeholder project'
    git -C $lab push -q origin main 2>&1 | Out-Null
    git -C $lab fetch -q template 2>&1 | Out-Null
}

# Leading commas throughout: an empty result would otherwise unroll to $null.
function Get-LabStatus { , @(git -C $lab status --porcelain) }
function Get-CommittedFile {
    , @(git -C $lab show --name-only --format='' HEAD | Where-Object { $_.Trim() })
}

function Get-Marker {
    $gateFolder = Get-LabPath '.git' 'new-repo-gate'
    , @(Get-ChildItem -LiteralPath $gateFolder -File -ErrorAction SilentlyContinue)
}

function Get-MarkerName { ((Get-Marker) | ForEach-Object Name) -join ', ' }

# The private gate plumbing, reached through the module's own scope.
function Test-Gate {
    param([Parameter(Mandatory)][string]$Message)

    return & $gitModule { param($p, $m) Test-CommitSubject -RepoPath $p -Message $m } $lab $Message
}

function Get-MarkerPath {
    param([Parameter(Mandatory)][string]$Message)

    return & $gitModule { param($p, $m) Get-GateMarkerPath -RepoPath $p -Message $m } $lab $Message
}

function Write-Marker {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Before
    )

    & $gitModule { param($k, $m, $b) Write-GateMarker -Path $k -Message $m -Before $b } `
        $Path $Message $Before
}

Write-TestSection '1. a non-ASCII filename is committed, not silently dropped'
# Arrange
New-Lab

# Act
Invoke-GatedCommit -RepoPath $lab -Message 'chore: unicode' -Body {
    Write-LabFile -Part "cafe`u{0301}.txt" -Text 'x'
    Write-LabFile -Part 'ascii.txt' -Text 'x'
}

# Assert
Assert-That 'the non-ASCII file made it into the commit' ((Get-CommittedFile).Count -eq 2) `
    "committed: $((Get-CommittedFile) -join ', ')"
Assert-That 'nothing left untracked afterwards' ((Get-LabStatus).Count -eq 0) `
    "left: $((Get-LabStatus) -join ' | ')"

Write-TestSection '2. a rename commits BOTH sides'
# Arrange
New-Lab
Write-LabFile -Part 'old name.txt' -Text 'some content here'
git -C $lab add -A
git -C $lab commit -q -m 'add'

# Act
Invoke-GatedCommit -RepoPath $lab -Message 'chore: rename' -Body {
    git -C $lab mv 'old name.txt' "ne`u{0301}w name.txt" 2>&1 | Out-Null
}

# Assert
Assert-That 'the rename left a clean tree' ((Get-LabStatus).Count -eq 0) `
    "left: $((Get-LabStatus) -join ' | ')"

Write-TestSection '3. with -Paths, work MODIFIED outside the pathspec is not staged'
# Arrange
New-Lab
Write-LabFile -Part 'README.md' -Text 'my own edit'

# Act
Invoke-GatedCommit -RepoPath $lab -Message 'chore: scoped' -Paths @('settings.yml') -Body {
    Write-LabFile -Part 'settings.yml' -Text 'scaffolded'
}

# Assert
$committed = Get-CommittedFile
Assert-That 'only the pathspec was committed' `
    ($committed.Count -eq 1 -and $committed[0] -eq 'settings.yml') `
    "committed: $($committed -join ', ')"
Assert-That "the developer's edit is still uncommitted" `
    ([bool]((Get-LabStatus) -match 'README\.md'))

Write-TestSection '4. without -Paths, work dirty BEFORE the body is not staged either'
# Arrange
New-Lab
Write-LabFile -Part 'README.md' -Text 'my own edit'

# Act
$run = Get-Narration {
    Invoke-GatedCommit -RepoPath $lab -Message 'chore: unrelated' -Body {
        Write-LabFile -Part 'other.txt' -Text 'scaffolded'
    }
}

# Assert
$committed = Get-CommittedFile
Assert-That 'only what the body dirtied was committed' `
    ($committed.Count -eq 1 -and $committed[0] -eq 'other.txt') `
    "committed: $($committed -join ', ')"
Assert-That "the developer's edit is still uncommitted" `
    ([bool]((Get-LabStatus) -match 'README\.md'))
Assert-That 'the excluded path was named in a warning' `
    ([bool]($run.Lines -match 'already modified') -and [bool]($run.Lines -match 'README\.md')) `
    ($run.Lines -join ' | ')
Assert-That 'no marker is left behind' ((Get-Marker).Count -eq 0) "markers: $(Get-MarkerName)"

Write-TestSection '5. a bad repo path fails loudly instead of reporting a skip'
# Arrange
$notRepo = New-TestFolder -Path (Join-Path $root 'not-a-repo')

# Act + Assert
Assert-Throws 'a non-repo throws, naming the failure' -Match 'not a git repository' `
    { Invoke-GatedCommit -RepoPath $notRepo -Message 'chore: nope' -Body { } }

Write-TestSection '6. the gate is exact and case-sensitive'
# Arrange
New-Lab
Invoke-GatedCommit -RepoPath $lab -Message 'chore: exact subject' -Paths @('a.txt') -Body {
    Write-LabFile -Part 'a.txt' -Text 'x'
}

# Act + Assert
Assert-That 'the exact subject satisfies the gate' (Test-Gate 'chore: exact subject')
Assert-That 'a different case does not' (-not (Test-Gate 'Chore: exact subject'))
Assert-That 'a prefix does not' (-not (Test-Gate 'chore: exact'))

Write-TestSection '7. Push-Repo reports what it actually did'
# Arrange
New-Lab
Write-LabFile -Part 'b.txt' -Text 'x'
git -C $lab add -A
git -C $lab commit -q -m 'something to push'

# Act + Assert
Assert-That 'a real push returns true' ([bool](Push-Repo -RepoPath $lab 6>$null))
Assert-That 'an up-to-date push returns false' (-not (Push-Repo -RepoPath $lab 6>$null))

Write-TestSection '8. a group that crashed half-way is resumed, not repeated'
# Arrange: a rename that will collide with a file already in the way.
New-PlaceholderLab -WithSquatter
$rename = { Rename-Token -RepoPath $lab -From 'Placeholder' -To 'MyProj' }

# Act + Assert
Assert-Throws 'the first attempt throws on the collision' -Match 'MyProj\.md' `
    { Invoke-GatedCommit -RepoPath $lab -Message 'chore: rename, interrupted' -Body $rename }
Assert-That 'the crash left a marker behind' ((Get-Marker).Count -eq 1) "markers: $(Get-MarkerName)"
Assert-That 'and left the tree half-renamed' ([bool]((Get-LabStatus) -match 'Placeholder')) `
    "status: $((Get-LabStatus) -join ' | ')"

# Arrange: the operator clears the collision and commits ONLY that.
Remove-Item -LiteralPath (Get-LabPath 'docs' 'MyProj.md') -Force
git -C $lab add -- 'docs/MyProj.md'
git -C $lab commit -q -m 'chore: clear the collision' -- 'docs/MyProj.md'
git -C $lab fetch -q template 2>&1 | Out-Null

# Act
$run = Get-Narration {
    Invoke-GatedCommit -RepoPath $lab -Message 'chore: rename, interrupted' -Body $rename
}

# Assert
Assert-That 'the resume says it is resuming' ([bool]($run.Lines -match 'Resuming')) `
    ($run.Lines -join ' | ')
Assert-That 'the resume leaves a clean tree' ((Get-LabStatus).Count -eq 0) `
    "left: $((Get-LabStatus) -join ' | ')"
Assert-That 'the gate is now satisfied' (Test-Gate 'chore: rename, interrupted')
$status = @(git -C $lab show --name-status --no-renames --format='' HEAD |
        Where-Object { $_.Trim() })
foreach ($old in 'src/Placeholder/Placeholder.csproj', 'src/Placeholder/Class1.cs',
    'docs/Placeholder.md') {
    Assert-That "the commit DELETES $old" `
        ([bool]($status -match "^D\s+$([regex]::Escape($old))$")) `
        ($status -join ' | ')
}

Assert-Equal "the commit holds the first attempt's README rewrite" -Expected '# MyProj readme' `
    -Actual (git -C $lab show HEAD:README.md)
Assert-That 'the marker is gone' ((Get-Marker).Count -eq 0)

Write-TestSection '9. a group that crashed AFTER its body still gets its commit'
# Arrange: the marker was written against a clean tree, the body ran to
# completion, and the process died before the commit.
New-PlaceholderLab
$subject = 'chore: rename, died before committing'
Write-Marker -Path (Get-MarkerPath $subject) -Message $subject -Before @()
Rename-Token -RepoPath $lab -From 'Placeholder' -To 'MyProj'
Assert-That 'the emulated crash left work uncommitted' ((Get-LabStatus).Count -gt 0)

# Act
Invoke-GatedCommit -RepoPath $lab -Message $subject -Body $rename

# Assert
Assert-That 'the resume committed the finished work' (Test-Gate $subject)
Assert-That 'and left a clean tree' ((Get-LabStatus).Count -eq 0) `
    "left: $((Get-LabStatus) -join ' | ')"
Assert-That 'the marker is gone' ((Get-Marker).Count -eq 0)

Write-TestSection "10. a developer's edit survives a crashed run untouched"
# Arrange
New-Lab
Write-LabFile -Part 'README.md' -Text 'MY OWN EDIT'
try {
    Invoke-GatedCommit -RepoPath $lab -Message 'chore: generate docs' -Body {
        Write-LabFile -Part 'gen1.txt' -Text 'g1'
        throw 'boom'
    }
}
catch { $null = $_ }

# Act
Invoke-GatedCommit -RepoPath $lab -Message 'chore: generate docs' -Body {
    Write-LabFile -Part 'gen2.txt' -Text 'g2'
}

# Assert
$committed = Get-CommittedFile
Assert-That "both attempts' files are in the one commit" `
('gen1.txt' -in $committed -and 'gen2.txt' -in $committed) "committed: $($committed -join ', ')"
Assert-That "the developer's edit is not" ('README.md' -notin $committed)
Assert-That 'and is still theirs to commit' ([bool]((Get-LabStatus) -match 'README\.md'))

Write-TestSection '11. the marker is removed on every way a group can finish'
# Arrange
New-Lab

# Act
Invoke-GatedCommit -RepoPath $lab -Message 'chore: nothing to do' -Body { }

# Assert
Assert-That 'gone after a no-op group' ((Get-Marker).Count -eq 0)

# Arrange: the subject is already in history, and a stale marker is planted.
git -C $lab commit -q --allow-empty -m 'chore: done by hand'
$stale = Get-MarkerPath 'chore: done by hand'
Write-Marker -Path $stale -Message 'chore: done by hand' -Before @('stale.txt')
Assert-That 'a stale marker was planted' (Test-Path -LiteralPath $stale)

# Act
Invoke-GatedCommit -RepoPath $lab -Message 'chore: done by hand' -Body {
    throw 'the body must not run'
}

# Assert
Assert-That 'gone when the gate was already satisfied' (-not (Test-Path -LiteralPath $stale))

Write-TestSection '12. the marker never reaches git'
# Arrange
New-Lab

# Act
try { Invoke-GatedCommit -RepoPath $lab -Message 'chore: leave a marker' -Body { throw 'boom' } }
catch { $null = $_ }

# Assert
$marker = Get-Marker
Assert-That 'a crashed attempt leaves exactly one marker' ($marker.Count -eq 1) `
    "markers: $(Get-MarkerName)"
Assert-That 'it lives under the git directory' ($marker[0].FullName -like (Get-LabPath '.git' '*'))
Assert-That 'git status does not see it' ((Get-LabStatus).Count -eq 0)
Assert-That 'git clean would not remove it' (-not @(git -C $lab clean -xfdn))

Write-TestSection '13. one subject gates one group per run'
# Arrange: gate a subject once, then start over with a fresh repo. The guard
# is per PROCESS, not per repo, so the same subject must be refused anywhere.
New-Lab
Invoke-GatedCommit -RepoPath $lab -Message 'chore: gate once' -Paths @('y.txt') -Body {
    Write-LabFile -Part 'y.txt' -Text 'x'
}

New-Lab

# Act + Assert
Assert-Throws 'a subject already used this run throws' -Match 'already gated' {
    Invoke-GatedCommit -RepoPath $lab -Message 'chore: gate once' -Paths @('z.txt') -Body {
        Write-LabFile -Part 'z.txt' -Text 'x'
    }
}

Assert-That 'and its body did not run' (-not (Test-Path (Get-LabPath 'z.txt')))

Write-TestSection '14. git output is always a flat array, whatever the line count'
# Arrange
New-Lab

# Act
$zero = Invoke-Git -Activity 't' -RepoPath $lab -Arguments @('log', '--format=%s', 'HEAD..HEAD')
$one = Invoke-Git -Activity 't' -RepoPath $lab -Arguments @('log', '--format=%s')
git -C $lab commit -q --allow-empty -m 'second'
$two = Invoke-Git -Activity 't' -RepoPath $lab -Arguments @('log', '--format=%s')
$remotes = & $gitModule { param($p) Read-GitOutput -RepoPath $p -Arguments @('remote') } $lab
$none = & $gitModule {
    param($p) Read-GitOutput -RepoPath $p -Arguments @('remote', 'get-url', 'nope')
} $lab

# Assert
Assert-That 'Invoke-Git: zero lines is an empty array' ($zero -is [array] -and $zero.Count -eq 0) `
    "got $($zero.GetType().Name) count=$($zero.Count)"
Assert-That 'Invoke-Git: one line is a one-element array of a string' `
($one -is [array] -and $one.Count -eq 1 -and $one[0] -is [string]) `
    "got $($one.GetType().Name) count=$($one.Count) [0]=$($one[0].GetType().Name)"
Assert-That 'Invoke-Git: two lines are two strings, not one array' `
    ($two.Count -eq 2 -and $two[0] -is [string]) `
    "got count=$($two.Count) [0]=$($two[0].GetType().Name)"
Assert-That 'Read-GitOutput: two remotes are two strings' `
    ($remotes.Count -eq 2 -and $remotes -contains 'template') `
    "got count=$($remotes.Count): $($remotes -join ' | ')"
Assert-That 'Read-GitOutput: a failing read is an empty array, not $null' `
    ($none -is [array] -and $none.Count -eq 0)

Write-TestSection '15. Get-RemoteUrl and Initialize-LocalRepo'
# Arrange
New-Lab

# Act + Assert
Assert-Equal 'a present remote' -Expected $bare `
    -Actual (Get-RemoteUrl -RepoPath $lab -Name template)
Assert-That 'a missing remote is $null' ($null -eq (Get-RemoteUrl -RepoPath $lab -Name nope))
Assert-That 'Initialize-LocalRepo twice does not re-add the remote' `
$(try {
        Initialize-LocalRepo -RepoPath $lab -TemplateUrl $bare 6>$null
        Initialize-LocalRepo -RepoPath $lab -TemplateUrl $bare 6>$null
        $true
    }
    catch { $false })

Write-TestSection '16. the module surface is only what a layer should touch'
$exported = (Get-Command -Module Common-Git).Name
foreach ($n in 'Get-DirtyPath', 'Test-CommitSubject', 'Invoke-StagedCommit', 'Invoke-GatedGroup',
    'Get-GateMarkerPath', 'Read-GateMarker', 'Write-GateMarker', 'Remove-GateMarker',
    'Resolve-GateBaseline', 'Test-GitSucceeds', 'Read-GitOutput') {
    Assert-That "$n stays private" ($n -notin $exported)
}

foreach ($n in 'Invoke-Git', 'Get-DefaultBranch', 'Get-RemoteUrl', 'Invoke-GatedCommit',
    'Initialize-Clone', 'Initialize-LocalRepo', 'Push-Repo') {
    Assert-That "$n is exported" ($n -in $exported)
}

exit (Complete-TestRun)
