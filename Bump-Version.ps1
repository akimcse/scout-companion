<#
.SYNOPSIS
    Works out the next version from a merge, and applies it.

.DESCRIPTION
    Called by .github/workflows/release.yml after a pull request lands on main.

    The logic lives here rather than inline in the workflow YAML for one reason:
    YAML is not testable. Everything that decides a version number is a function
    in this file, and Test-SessionMatch.ps1 lifts those functions out and tests
    them the same way it tests the app.

.NOTES
    Three components, never four. The update check compares three, so 0.8.2.1
    and 0.8.2 are equal to it and nobody would ever be offered the newer one -
    and every already-installed copy has that same three-part comparison baked
    in, so adopting a build number now would strand them silently. Measured, and
    pinned by Test-SessionMatch.
#>
[CmdletBinding()]
param(
    # The merge commit's subject line, in either of the two shapes GitHub
    # produces:
    #   "Merge pull request #29 from someone/fix/one-companion-at-a-time"
    #   "Stop two companions running at once (#29)"
    [string]$Subject,

    # The branch the pull request came from, when the subject cannot say.
    # A squash merge keeps the pull request number and drops the branch, so the
    # workflow looks it up and passes it here rather than this file reaching
    # for the network - the decision stays a pure function, and testable.
    [string]$Branch,

    # Path to the script carrying $CompanionVersion.
    [string]$AppPath = (Join-Path $PSScriptRoot 'scout-companion.ps1'),

    # Work out the answer and print it, changing nothing.
    [switch]$WhatIf
)

# The pull request number a merge commit refers to, or '' if it is not one.
#
# Both shapes have to be recognised. GitHub's merge-commit subject names the
# branch; the squash subject does not, and "Squash and merge" is one click away
# from "Merge pull request" in the same dropdown. Only the first was matched, so
# a squash merge released nothing - and said so in a step that reported success,
# which is the quietest way for work to not reach anyone. Measured: #48 merged,
# workflow green, no release, version untouched.
function Get-MergedPrNumber([string]$subject) {
    if (-not $subject) { return '' }
    if ($subject -match '^Merge pull request #(\d+) from ') { return $matches[1] }
    if ($subject -match '\(#(\d+)\)\s*$')                   { return $matches[1] }
    return ''
}

# The branch a merge-commit subject names, or '' if it does not name one.
function Get-MergedBranch([string]$subject) {
    if (-not $subject) { return '' }
    # BRANCH itself contains slashes - so take everything after the first one.
    if ($subject -match '^Merge pull request #\d+ from [^/]+/(.+)$') { return $matches[1].Trim() }
    return ''
}

# What kind of bump a merge earns, read from the branch it came from.
#
# The branch prefix is used because it is already the convention here and has
# been for every merge: 21 of them, feat/ fix/ chore/ docs/ perf/. It is also
# the signal that was right when the version number was wrong - v0.5.0 came
# from a branch named fix/, and should have been a patch.
#
# Returns 'minor', 'patch', or '' for anything that is not a merged pull
# request. A direct push to main releases nothing: everything here goes through
# a PR, so a bare push is either an accident or work in progress, and neither
# deserves to reach people running the auto-updater.
function Get-BumpKind([string]$subject, [string]$branch = '') {
    if (-not (Get-MergedPrNumber $subject)) { return '' }

    # A branch supplied by the caller wins: for a squash merge it is the only
    # source, and for a merge commit it is the same answer.
    if (-not $branch) { $branch = Get-MergedBranch $subject }
    $branch = ([string]$branch).Trim()

    # "now it does X" is a minor; "X now works" is a patch. Below 1.0 a new
    # capability moves the minor, which is what feat/ means here.
    if ($branch -match '^feat(ure)?/') { return 'minor' }
    if ($branch -match '^(fix|chore|docs|perf|refactor|test|build|ci)/') { return 'patch' }

    # An unprefixed branch - or a squash merge whose branch could not be looked
    # up, which is the same state of knowledge - is not a reason to guess at
    # intent, but it is also not a reason to publish nothing: a merge that
    # changes the app and never reaches anyone is worse than one released
    # conservatively.
    return 'patch'
}

# Apply a bump to a three-part version.
#
# major is never automated. It is a claim that something people rely on has
# changed shape, and nothing about a branch name can establish that.
function Get-NextVersion([string]$current, [string]$kind) {
    if (-not $current) { throw 'no current version' }
    if ($current -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        throw "version '$current' is not three components - see the note at the top of this file"
    }
    $maj = [int]$matches[1]; $min = [int]$matches[2]; $pat = [int]$matches[3]
    switch ($kind) {
        'minor' { return "$maj.$($min + 1).0" }
        'patch' { return "$maj.$min.$($pat + 1)" }
        default { throw "unknown bump kind '$kind'" }
    }
}

# Read and write the one line that carries the version, without disturbing the
# rest of a 4,000-line script.
function Get-DeclaredVersion([string]$path) {
    $m = Select-String -Path $path -Pattern "^\`$CompanionVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    if (-not $m) { throw "no `$CompanionVersion in $path" }
    return $m.Matches[0].Groups[1].Value
}

function Set-DeclaredVersion([string]$path, [string]$version) {
    $text = Get-Content $path -Raw
    $new = [regex]::Replace(
        $text,
        "(?m)^(\`$CompanionVersion\s*=\s*')[^']+(')",
        { param($m) $m.Groups[1].Value + $version + $m.Groups[2].Value },
        1)
    if ($new -eq $text) { throw "version line in $path did not change" }

    # Write with .NET and an explicit encoding, preserving whatever byte order
    # mark the file already had.
    #
    # Set-Content -Encoding UTF8 cannot be used here: it means "with a BOM" in
    # Windows PowerShell and "without one" in PowerShell 7, and the workflow
    # runs this under 7. So the release process stripped the BOM from
    # scout-companion.ps1 - which contains non-ASCII - and Windows PowerShell
    # then reads such a file in the system ANSI codepage. Every automated
    # release would have shipped an app that does not parse outside a codepage
    # that happens to tolerate those bytes. Caught by the test that requires a
    # BOM on any non-ASCII script, on the run right after it was added.
    $bytes  = [System.IO.File]::ReadAllBytes($path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    # -NoNewline equivalent: the file has no trailing blank line, and adding one
    # would show up as a spurious diff on every release.
    [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding($hasBom)))
}

# Running this file directly is what the workflow does; dot-sourcing it is what
# the tests do, and they must not trigger a bump.
if ($MyInvocation.InvocationName -ne '.') {
    $kind = Get-BumpKind $Subject $Branch
    if (-not $kind) {
        Write-Host "not a merged pull request - nothing to release"
        if ($env:GITHUB_OUTPUT) { "bumped=false" | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8 }
        exit 0
    }

    $current = Get-DeclaredVersion $AppPath
    $next    = Get-NextVersion $current $kind

    Write-Host "  branch kind : $kind"
    Write-Host "  current     : $current"
    Write-Host "  next        : $next"

    if (-not $WhatIf) { Set-DeclaredVersion $AppPath $next }

    if ($env:GITHUB_OUTPUT) {
        "bumped=true"        | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
        "version=$next"      | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
        "previous=$current"  | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
        "kind=$kind"         | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
}
