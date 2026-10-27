# Tests\Drift.Tests.ps1
#
# Build hygiene plus drift between src\ and the versioned AutoRDPwn.ps1.
#
# Drift is reported as a warning (skip), never as a failure: src\*.ps1 is under
# active edit, so the versioned build is expected to lag until someone rebuilds
# it on purpose. The hard test here is that this suite never rebuilds it by
# accident - Build.ps1 without -OutputPath overwrites AutoRDPwn.ps1 and would
# destroy in-flight work.

# Commands that actually invoke Build.ps1. A command that merely mentions the
# name in an argument ("It 'build gate...'") is not an invocation.
function Get-ArBuildInvocations {
    param([Parameter(Mandatory = $true)][string]$Path)
    $parsed = Get-ArParseResult -Path $Path
    $candidates = @($parsed.Ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
        $name = $node.GetCommandName()
        if (-not [string]::IsNullOrWhiteSpace($name)) { return ($name -match '(?i)build\.ps1$') }
        if ($node.CommandElements.Count -eq 0) { return $false }
        return ($node.CommandElements[0].Extent.Text -match '(?i)build\.ps1')
    }, $true))
    return $candidates
}

Describe 'build drift' {

    It 'sandbox output is not the versioned build' {
        $versioned = Join-Path $script:ArTestRoot 'AutoRDPwn.ps1'
        Assert-True ($script:ArTestGenPath -ne $versioned) `
            ('the runner is configured to write gen.ps1 over AutoRDPwn.ps1 (' + $versioned + ')')
        Assert-True ($script:ArTestGenPath.StartsWith($script:ArTestSandbox, [System.StringComparison]::OrdinalIgnoreCase)) `
            ('gen.ps1 must live under _sandbox\, got ' + $script:ArTestGenPath)
    }

    It 'suite never invokes Build.ps1 without -OutputPath' {
        # Every Build.ps1 command in Tests\*.ps1 must carry -OutputPath, otherwise
        # Build.ps1 writes AutoRDPwn.ps1 and in-flight work is lost.
        $offenders = New-Object System.Collections.ArrayList
        foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
            foreach ($call in @(Get-ArBuildInvocations -Path $file.FullName)) {
                if ($call.Extent.Text -notmatch '-OutputPath') {
                    $null = $offenders.Add(('{0}:{1}: {2}' -f $file.Name, $call.Extent.StartLineNumber, $call.Extent.Text))
                }
            }
        }
        if ($offenders.Count -eq 0) { return }
        throw ('Build.ps1 invoked without -OutputPath; that overwrites AutoRDPwn.ps1: ' + (($offenders) -join '; '))
    }

    It ('sandbox build is newer than every source part') {
        Assert-FileExists -Path $script:ArTestGenPath -Message 'the runner did not produce _sandbox\gen.ps1'
        $genTime = (Get-Item -LiteralPath $script:ArTestGenPath).LastWriteTimeUtc
        $stale = @()
        foreach ($path in @(Get-ArSourceFilePaths)) {
            if ((Get-Item -LiteralPath $path).LastWriteTimeUtc -gt $genTime) { $stale += (Split-Path -Leaf $path) }
        }
        Assert-True ($stale.Count -eq 0) ('sources edited after the sandbox build: ' + ($stale -join ', '))
    }

    It-Warn 'versioned AutoRDPwn.ps1 matches src' {
        $versioned = Join-Path $script:ArTestRoot 'AutoRDPwn.ps1'
        Assert-FileExists -Path $versioned -Message 'AutoRDPwn.ps1 is missing from the repository root'
        $generatedLines = @((Get-Content -LiteralPath $script:ArTestGenPath -Raw) -split "\r?\n" | ForEach-Object { $_.TrimEnd() })
        $versionedLines = @((Get-Content -LiteralPath $versioned -Raw) -split "\r?\n" | ForEach-Object { $_.TrimEnd() })

        $max = [Math]::Min($generatedLines.Count, $versionedLines.Count)
        $firstDifference = -1
        for ($index = 0; $index -lt $max; $index++) {
            if ($generatedLines[$index] -cne $versionedLines[$index]) {
                $firstDifference = $index
                break
            }
        }
        if ($firstDifference -lt 0 -and $generatedLines.Count -ne $versionedLines.Count) { $firstDifference = $max }
        if ($firstDifference -lt 0) { return }

        $changed = @(Compare-Object -ReferenceObject $generatedLines -DifferenceObject $versionedLines -SyncWindow 0)
        $sample = ''
        if ($firstDifference -lt $versionedLines.Count) { $sample = $versionedLines[$firstDifference].Trim() }
        if ($sample.Length -gt 120) { $sample = $sample.Substring(0, 120) + '...' }
        throw ('generated build differs from src (first difference at line {0}, {1} line(s) changed). Rebuild with: .\Build.ps1 -OutputPath AutoRDPwn.ps1. Line {0} of AutoRDPwn.ps1: {2}' -f
            ($firstDifference + 1), $changed.Count, $sample)
    }

    It-Warn 'src persists the last used profile' {
        # last.json is part of the profile contract. The versioned build writes it
        # from Save-ARTargetProfile; the source tree currently does not.
        $function = Get-ArFunctionAst -Name 'Save-ARTargetProfile'
        Assert-NotNull $function 'Save-ARTargetProfile is not defined in any src\*.ps1'
        $calls = @(Get-ArCommandAsts -Ast $function.Ast.Body -Name 'Set-ARLastProfileName')
        Assert-True ($calls.Count -gt 0) `
            'src\Save-ARTargetProfile never calls Set-ARLastProfileName, so last.json is never refreshed from the source build'
    }

    It-Warn 'src defines every function the entry point calls' {
        # 50-main.ps1 boots the app; a function it calls that no src file defines
        # means the source build dies before the menu is drawn.
        $function = Get-ArFunctionAst -Name 'Start-ARApplication'
        Assert-NotNull $function 'Start-ARApplication is missing from src\*.ps1'
        $defined = @(Get-ArFunctionNames)
        $missing = New-Object System.Collections.ArrayList
        $calls = @($function.Ast.Body.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true))
        foreach ($call in $calls) {
            $name = $call.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -notmatch '^[A-Z][a-z]+-[A-Z]') { continue }
            if ($defined -notcontains $name) { $null = $missing.Add(('{0} ({1}:{2})' -f $name, 'src', $call.Extent.StartLineNumber)) }
        }
        if ($missing.Count -eq 0) { return }
        throw ('Start-ARApplication calls helpers that no src\*.ps1 defines: ' + (($missing | Sort-Object -Unique) -join ', '))
    }
}
