#Requires -Version 7.0
<#
    Rewriting a freshly cloned repo's inherited files into its own - which
    template-only files to drop, the README, the LICENSE, and settings.yml.

    Inherited by merge, so keep it identical at every layer:
    a per-layer edit conflicts on every future template change.
#>

Set-StrictMode -Version Latest

# Module scope has its own preference, so the calling script's 'Stop' never
# reaches these functions. Without this, a failing cmdlet is non-terminating
# and the Write-Ok on the next line reports a success that never happened.
$ErrorActionPreference = 'Stop'

#───────────────────────────────────────────────────────────────────────────────
# Configuration
#───────────────────────────────────────────────────────────────────────────────

# The section rule and plugin doc link that every settings.yml block repeats.
# Indented under 'repository:'; SettingsRuleTop is for a top-level key.
$script:SettingsRule = '  #' + ('─' * 77)
$script:SettingsRuleTop = '#' + ('─' * 79)
$script:SettingsPluginDoc = '  # https://github.com/repository-settings/app' +
    '/blob/master/docs/plugins/repository.md'

# Files that exist ONLY in the base .github repo.
# Single source of truth: the same table drives both the deletion
# and the README de-linking, so the two can't drift apart.
# 'Label' is the markdown link-reference label the README uses for it.
$script:TemplateOnlyFiles = @(
    @{ Path = '.github/FUNDING.yml'; Label = 'fundingFile' }
    @{ Path = '.github/ISSUE_TEMPLATE/config.yml'; Label = 'issueChooserFile' }
)

#───────────────────────────────────────────────────────────────────────────────
# Inherited files a derived repo drops
#───────────────────────────────────────────────────────────────────────────────

function Remove-TemplateOnlyFile {
    <#
    .SYNOPSIS
        Deletes the files listed in $TemplateOnlyFiles,
        which live ONLY in the base .github repo.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath
    )

    Write-Doing 'Deleting the template-only files'
    $gone = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $script:TemplateOnlyFiles) {
        $file = Join-Path $RepoPath $entry.Path
        if (-not (Test-Path $file)) { continue }
        Remove-Item $file
        $gone.Add($entry.Path)
    }

    if ($gone.Count -eq 0) {
        Write-Done -Skip 'none left to delete'
        return
    }

    Write-Done "$($gone.Count) file(s)"
    foreach ($path in $gone) { Write-Detail $path }
    Add-Change
}

function Remove-ScriptsFolder {
    <#
    .SYNOPSIS
        Deletes the scripts/ folder and its CI workflow in a code repo, since
        nothing is derived from one and there is nothing left to test.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath
    )

    Write-Doing 'Removing scripts/'
    $dir = Join-Path $RepoPath 'scripts'
    $workflow = Join-Path $RepoPath '.github/workflows/test-scripts.yml'
    if (-not (Test-Path $dir) -and -not (Test-Path $workflow)) {
        Write-Done -Skip 'already removed'
        return
    }

    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    if (Test-Path $workflow) { Remove-Item $workflow }
    Add-Change
    Write-Done 'nothing is derived from a code repo'
}

#───────────────────────────────────────────────────────────────────────────────
# Docs & references
#───────────────────────────────────────────────────────────────────────────────

function Update-RepoReference {
    <#
    .SYNOPSIS
        Replaces references to the source template's owner/repo with the new one's.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$OldOwnerRepo,
        [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$NewOwnerRepo
    )

    Write-Doing "Retargeting '$OldOwnerRepo' -> '$NewOwnerRepo'"
    $targets = [System.Collections.Generic.List[string]]::new()
    $targets.AddRange(
        [string[]]@('CONTRIBUTING.md', 'SECURITY.md', 'SUPPORT.md'))
    $issueDir = Join-Path $RepoPath '.github/ISSUE_TEMPLATE'
    if (Test-Path $issueDir) {
        $forms = Get-ChildItem $issueDir -File
        foreach ($form in $forms) {
            $targets.Add(".github/ISSUE_TEMPLATE/$($form.Name)")
        }
    }

    $updated = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $targets) {
        $file = Join-Path $RepoPath $rel
        if (-not (Test-Path $file)) { continue }
        # Through Common-Text, so the file keeps the encoding it arrived with.
        if (Update-FileToken -Path $file -From $OldOwnerRepo -To $NewOwnerRepo) {
            $updated.Add($rel)
        }
    }

    if ($updated.Count -eq 0) {
        # Said out loud: a re-run and a target list that has silently gone
        # stale otherwise look identical, because both print nothing.
        Write-Done -Skip "no '$OldOwnerRepo' references left to retarget"
        return
    }

    Write-Done "$($updated.Count) file(s)"
    foreach ($rel in $updated) { Write-Detail $rel }
    Add-Change
}

#───────────────────────────────────────────────────────────────────────────────
# README
#───────────────────────────────────────────────────────────────────────────────

function Update-Readme {
    <#
    .SYNOPSIS
        De-links the README rows for the template-only files,
        then prunes the orphaned link definitions.
    .DESCRIPTION
        De-links rather than deletes:
        the table's "Exists only in .github repo" column
        is what documents that the file is deliberately absent here,
        so the row must survive.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath
    )

    Write-Doing 'De-linking the template-only files in README.md'
    $file = Join-Path $RepoPath 'README.md'
    if (-not (Test-Path $file)) {
        Write-Done -Skip 'README.md not found'
        return
    }

    $readme = Read-TextFile -Path $file
    $raw = $readme.Content
    $original = $raw

    # 1) '[Display Name][label]' -> 'Display Name', keeping the table row.
    foreach ($label in @($script:TemplateOnlyFiles.Label)) {
        $raw = $raw -replace "\[([^\]]+)\]\[$([regex]::Escape($label))\]", '$1'
    }

    # 2) Garbage-collect '[label]: url' definitions nothing references any more.
    $lines = [System.Collections.Generic.List[string]]@($raw -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '^\[(?<label>[^\]]+)\]:\s') { continue }
        $token = "[$($Matches['label'])]"
        $used = $false
        for ($j = 0; $j -lt $lines.Count; $j++) {
            if ($j -eq $i) { continue }
            # Other definitions aren't usages.
            if ($lines[$j] -match '^\[[^\]]+\]:\s') { continue }
            if ($lines[$j].Contains($token)) { $used = $true; break }
        }

        if (-not $used) { $lines.RemoveAt($i) }
    }

    $eol = $readme.LineEnding
    $raw = $lines -join $eol
    if (-not $raw.EndsWith($eol)) { $raw += $eol }

    if ($raw -eq $original) {
        Write-Done -Skip 'already de-linked'
        return
    }

    Write-TextFile -Path $file -Content $raw
    Add-Change
    Write-Done
}

function Test-TemplateReadme {
    <#
    .SYNOPSIS
        Reports whether a README is still recognisably a template's.
    .DESCRIPTION
        Not exported. Two markers, either of which only a template's README
        carries. This is what stops a re-run overwriting the real README that
        was written afterwards - and a missing file answers false, so the
        caller skips rather than throwing.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return $false }

    $raw = Get-Content -Raw $Path
    return (
        $raw.Contains('Personal GitHub Repo Structure') -or
        $raw.Contains('Description of Files in This Template Repo')
    )
}

function Get-ProjectReadme {
    <#
    .SYNOPSIS
        Builds an ordinary project README: what this is, how to start, and
        where the community files are.
    .DESCRIPTION
        Not exported. Private and public repos differ in exactly two places -
        how to contribute, and the licence - so those are chosen up front and
        the rest of the skeleton is shared.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )

    $private = $Visibility -eq 'Private'
    $summary = if ($Description) { $Description } else { 'TODO: what this is.' }
    $contributing = if ($private) {
        'This is a private project. Please contact the owner before'
    }
    else { 'Contributions are welcome. Please read' }
    $licence = if ($private) {
        'All rights reserved. See [LICENSE][licenseFile].'
    }
    else { '[MIT][licenseFile]' }

    $lines = @(
        "# $RepoName <!-- omit from toc -->"
        ''
        $summary
        ''
        '#### Table of Contents <!-- omit from toc -->'
        ''
        '- [Getting Started](#getting-started)'
        '- [Contributing](#contributing)'
        '- [Support](#support)'
        '- [License](#license)'
        ''
        '## Getting Started'
        ''
        '> TODO: how to install this, and how to use it.'
        ''
        '## Contributing'
        ''
        $contributing
    )

    if ($private) {
        $lines += 'opening an issue or a pull request.'
    }
    else {
        $lines += '[CONTRIBUTING.md][contribFile] first,'
        $lines += 'along with the [Code of Conduct][cocFile].'
    }

    $lines += @(
        ''
        '## Support'
        ''
        'Need help? See [SUPPORT.md][supportFile].'
        'To report a vulnerability, see [SECURITY.md][securityFile].'
        ''
        '## License'
        ''
        $licence
        ''
        '<!-- Source Code URIs (alphabetical by file hierarchy) -->'
        ''
        '[cocFile]: ./CODE_OF_CONDUCT.md'
        '[contribFile]: ./CONTRIBUTING.md'
        '[licenseFile]: ./LICENSE'
        '[securityFile]: ./SECURITY.md'
        '[supportFile]: ./SUPPORT.md'
    )

    return $lines
}

function Reset-Readme {
    <#
    .SYNOPSIS
        Replaces a code repo's inherited README with an ordinary project one.
    .DESCRIPTION
        A template's README documents the template chain - the structure
        diagram and the inventory of which file lives at which layer. None of
        that means anything in a leaf repo, and an outside contributor reading
        it learns nothing about the project.

        Skipped unless the README is still recognisably the template's, so a
        re-run never overwrites the real README you wrote afterwards.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )

    Write-Doing 'Replacing the template README with a project one'
    $path = Join-Path $RepoPath 'README.md'
    if (-not (Test-TemplateReadme -Path $path)) {
        Write-Done -Skip 'not the template README - left alone'
        return
    }

    $lines = Get-ProjectReadme -RepoName $RepoName `
        -Description $Description `
        -Visibility $Visibility
    Write-TextFile -Path $path -Lines $lines
    Add-Change
    Write-Done
}

function Update-ReadmeDiagram {
    <#
    .SYNOPSIS
        Points the README's structure diagram at the template row.
    .DESCRIPTION
        The base .github repo highlights itself, next to the note explaining
        what it is. Every template derived from it highlights the right-most
        template in the second row instead, next to the note about template
        layers, so the picture reads "you are a layer" rather than "you are
        the base". Which tier is highlighted does not matter - the point is to
        convey the layering.

        Only the BASE repo's marker is ever retargeted. That makes this both
        idempotent and correct at any depth: a second-layer template inherits
        a diagram already pointing at the template row, so there is nothing
        to change, and a repo whose diagram was rewritten by hand is left
        alone.

        A code repo never gets here - Reset-Readme has already replaced the
        whole README, diagram included.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath
    )

    Write-Doing 'Retargeting the README diagram at the template row'
    $path = Join-Path $RepoPath 'README.md'
    if (-not (Test-Path $path)) {
        Write-Done -Skip 'README.md not found'
        return
    }

    $from = 'class github current'
    $to = 'class templateB current'

    $raw = (Read-TextFile -Path $path).Content
    if (-not $raw.Contains($from)) {
        Write-Done -Skip 'the diagram does not highlight the base repo'
        return
    }

    Write-TextFile -Path $path -Content $raw.Replace($from, $to)
    Add-Change
    Write-Done
}

function Set-ReadmeTitle {
    <#
    .SYNOPSIS
        Renames the README's heading to this repo.
    .DESCRIPTION
        A derived template inherits the base README, heading included, so
        without this every repo in the chain introduces itself as
        '.github Repository'. Only the first heading is touched; the rest of
        the document belongs to whoever edits it next.

        A code repo does not need this - Reset-Readme replaces the whole file,
        because a leaf should document the project rather than the chain.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [Parameter(Mandatory)][string]$RepoName
    )

    Write-Doing "Retitling the README to '$RepoName'"
    $path = Join-Path $RepoPath 'README.md'
    if (-not (Test-Path $path)) {
        Write-Done -Skip 'README.md not found'
        return
    }

    $raw = (Read-TextFile -Path $path).Content

    # Anchored to the first line so a '# ' inside the document, or inside a
    # fenced block, cannot be mistaken for the title.
    $pattern = '^#\s+(\S+)\s+Repository'
    if ($raw -notmatch $pattern) {
        Write-Done -Skip 'no recognizable title to rename'
        return
    }

    if ($Matches[1] -eq $RepoName) {
        Write-Done -Skip 'already named'
        return
    }

    $updated = [regex]::Replace($raw, $pattern, "# $RepoName Repository", 1)
    Write-TextFile -Path $path -Content $updated
    Add-Change
    Write-Done
}

#───────────────────────────────────────────────────────────────────────────────
# License
#───────────────────────────────────────────────────────────────────────────────

function Get-ProprietaryLicense {
    <#
    .SYNOPSIS
        Returns the all-rights-reserved notice, as lines.
    .DESCRIPTION
        Not exported. Kept apart from the policy that decides whether to write
        it, the same way the settings.yml blocks are.
    #>
    param([Parameter(Mandatory)][string]$Copyright)

    return @(
        'All Rights Reserved'
        ''
        $Copyright
        ''
        'This software and its source code are proprietary and confidential.'
        ''
        'No permission is granted to any person to use, copy, modify, merge,'
        'publish, distribute, sublicense, or sell copies of this software, in'
        'whole or in part, by any means, without the prior written permission'
        'of the copyright holder. Unauthorized copying, distribution, or use,'
        'via any medium, is strictly prohibited.'
        ''
        'To enquire about a licence, contact the copyright holder.'
        ''
        'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,'
        'EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF'
        'MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND'
        'NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS'
        'BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN'
        'ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN'
        'CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE'
        'SOFTWARE.'
    )
}

function Set-RepoLicense {
    <#
    .SYNOPSIS
        Replaces the inherited MIT license with a proprietary notice,
        for a private repo.
    .DESCRIPTION
        MIT grants everyone the right to use, copy and sell the code, which
        is the opposite of what a private repo wants. No OSI-approved licence
        can express "nobody may use this without an arrangement", because
        permitting use is what makes a licence open source - so a private repo
        gets an explicit all-rights-reserved notice instead.

        The existing copyright line is carried over verbatim, so the holder
        and year stay whatever the chain already says - or, when the inherited
        LICENSE has no such line, a bare "Copyright (c) <this year>" with no
        holder, which is a prompt to go and fill one in.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )

    Write-Doing 'Replacing the MIT license with an all-rights-reserved notice'
    if ($Visibility -ne 'Private') {
        Write-Done -Skip 'public repo - keeping the inherited MIT license'
        return
    }

    $path = Join-Path $RepoPath 'LICENSE'
    if (-not (Test-Path $path)) {
        Write-Warn 'LICENSE not found'
        return
    }

    $raw = (Read-TextFile -Path $path).Content
    if ($raw.StartsWith('All Rights Reserved')) {
        Write-Done -Skip 'already proprietary'
        return
    }

    $copyright = "Copyright (c) $((Get-Date).Year)"
    if ($raw -match 'Copyright \(c\)[^\r\n]*') { $copyright = $Matches[0] }
    else { Write-Warn 'No copyright line to carry over - add a holder to LICENSE' }

    $lines = Get-ProprietaryLicense -Copyright $copyright
    Write-TextFile -Path $path -Lines $lines
    Add-Change
    Write-Done
    Write-Detail 'GitHub shows no licence badge for a proprietary repo'
}

#───────────────────────────────────────────────────────────────────────────────
# settings.yml
#───────────────────────────────────────────────────────────────────────────────

function Get-SettingsAboutBlock {
    <#
    .SYNOPSIS
        Returns the "About" lines: description, homepage, topics.
    .DESCRIPTION
        Not exported. homepage is always written explicitly, even blank -
        _extends resolves recursively, so leaving the key out would inherit
        the parent's homepage instead of this repo having none.
    #>
    param(
        [Parameter(Mandatory)][string]$Description,
        [AllowEmptyString()][string]$Homepage,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Topics
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(
        $script:SettingsRule
        '  # "About" section (on Home Page)'
        $script:SettingsPluginDoc
        '  # https://docs.github.com/en/rest/repos/repos#update-a-repository'
        $script:SettingsRule
        ''
        '  # A short description of the repo'
        '  # MUST BE A SINGLE LINE'
        "  description: $Description"
        ''
        '  # A URL with more information about the repo'
        $(if ($Homepage) { "  homepage: $Homepage" } else { '  homepage: ""' })
    ))

    $lines.AddRange([string[]]@(
        ''
        '  # A comma-separated list of topics to set on the repo'
        '  # See https://github.com/topics'
        "  topics: $Topics"
    ))

    return $lines
}

function Get-SettingsGeneralBlock {
    <#
    .SYNOPSIS
        Returns the General lines: the repo name, and visibility when it is private.
    .DESCRIPTION
        Not exported. Visibility is stated only when it differs from the
        inherited default, so a repo meant to be public never carries a line
        that could flip it.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(
        ''
        $script:SettingsRule
        '  # Settings → General'
        $script:SettingsPluginDoc
        '  # https://docs.github.com/en/rest/repos/repos#update-a-repository'
        $script:SettingsRule
        ''
        '  # The name of the repo'
        "  name: $Name"
    ))

    if ($Visibility -eq 'Private') {
        $lines.AddRange([string[]]@('', '  # Visibility', '  private: true'))
    }

    return $lines
}

function Get-SettingsLeafBlock {
    <#
    .SYNOPSIS
        Returns the overrides only a leaf repo needs: not a template, merge
        commits allowed, linear history switched off.
    .DESCRIPTION
        Not exported. Nothing else in the chain differs by Kind, which is why
        this is one block rather than conditionals sprinkled through the file.
        Only keys that actually differ from the parent's are here, each
        keeping the parent's own comment - a value equal to the inherited one
        is not an override, and restating it risks drifting from the parent
        without anyone noticing.
    #>
    return @(
        ''
        '  # Whether the repo is available as a template'
        '  is_template: false'
        ''
        '  # Whether to allow merging pull requests with a merge commit'
        '  allow_merge_commit: true'
        ''
        '  # Whether to allow rebase-merging pull requests'
        '  allow_rebase_merge: false'
        ''
        $script:SettingsRuleTop
        '# Settings → Rules → Rulesets'
        '# https://github.com/repository-settings/app/blob/master/docs/plugins/rulesets.md'
        '# https://docs.github.com/en/rest/repos/rules#update-a-repository-ruleset'
        '# https://github.com/github/ruleset-recipes'
        $script:SettingsRuleTop
        'rulesets:'
        '  # Only template layers need linear history. Inheritance is'
        '  # additive, so this can be switched off here but never removed.'
        '  - name: Require linear history'
        '    enforcement: disabled'
    )
}

function Write-SettingsFile {
    <#
    .SYNOPSIS
        Writes the _extends settings.yml: what this repo overrides, and
        nothing the chain already says.
    .DESCRIPTION
        Skipped only when the file already names THIS repo. Testing for
        '_extends:' alone would wrongly preserve the parent's inherited
        settings.yml.

        A leaf gets more than a template does - is_template off, merge-commit
        policy, and a rulesets block turning off linear history - because
        those are the only settings that differ by Kind.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$RepoPath,
        [Parameter(Mandatory)][ValidateSet('Template', 'Code')][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExtendsRepo,
        [Parameter(Mandatory)][string]$Description,
        [string]$Homepage,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Topics,
        [ValidateSet('Public', 'Private')][string]$Visibility = 'Public'
    )

    Write-Doing 'Writing .github/settings.yml'
    $settingsPath = Join-Path $RepoPath '.github/settings.yml'
    if (Test-Path $settingsPath) {
        $existing = (Read-TextFile -Path $settingsPath).Content
        $namePattern = "(?m)^[ \t]*name:[ \t]*$([regex]::Escape($Name))[ \t]*\r?$"
        if ($existing -match $namePattern) {
            Write-Done -Skip "already targets '$Name'"
            return
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]@(
        '# Inherit everything from the immediate parent template and override'
        '# only what differs. The Settings app resolves _extends RECURSIVELY,'
        '# so this repo also picks up every ancestor through the chain'
        '# (e.g. .template-dotnet -> .github). Bare repo name = same owner.'
        "_extends: $ExtendsRepo"
        ''
        'repository:'
    ))

    $about = Get-SettingsAboutBlock -Description $Description `
        -Homepage $Homepage `
        -Topics $Topics
    $lines.AddRange([string[]]$about)
    $general = Get-SettingsGeneralBlock -Name $Name -Visibility $Visibility
    $lines.AddRange([string[]]$general)
    if ($Kind -eq 'Code') { $lines.AddRange([string[]](Get-SettingsLeafBlock)) }

    $settingsDir = Split-Path -Parent $settingsPath
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Force $settingsDir | Out-Null
    }

    # A brand-new settings.yml takes its line ending from the README beside
    # it, so it matches the rest of the checkout on either platform.
    Write-TextFile -Path $settingsPath -Lines $lines `
        -LikeFilePath (Join-Path $RepoPath 'README.md')
    Add-Change
    Write-Done "$($Kind.ToLowerInvariant()) repo"
}

Export-ModuleMember -Function @(
    'Remove-TemplateOnlyFile'
    'Remove-ScriptsFolder'
    'Update-RepoReference'
    'Update-Readme'
    'Update-ReadmeDiagram'
    'Set-ReadmeTitle'
    'Reset-Readme'
    'Set-RepoLicense'
    'Write-SettingsFile'
)
