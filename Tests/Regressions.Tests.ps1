# Tests\Regressions.Tests.ps1
#
# Guards for bugs that were already fixed once. They are text patterns on src\,
# not on the generated build, so they keep working while AutoRDPwn.ps1 lags
# behind src\.
#
# Each entry names the bug, not the implementation: a renamed helper does not
# break them, a reintroduced bug does.

function Get-ArRepositoryText {
    param([string[]]$RelativePath)
    $parts = New-Object System.Collections.ArrayList
    foreach ($relative in $RelativePath) {
        $path = Join-Path $script:ArTestRoot $relative
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $null = $parts.Add((Get-Content -LiteralPath $path -Raw))
    }
    return ($parts -join [Environment]::NewLine)
}

Describe 'regressions' {

    $sourceText = Get-ArRepositoryText -RelativePath @(Get-ChildItem -LiteralPath (Join-Path $script:ArTestRoot 'src') -Filter '*.ps1' -File |
            ForEach-Object { 'src\' + $_.Name })
    $stealthPath = Join-Path $script:ArTestRoot 'Resources\Scripts\Invoke-StealthScreen.ps1'
    $stealthText = Get-ArRepositoryText -RelativePath @('Resources\Scripts\Invoke-StealthScreen.ps1')

    It 'src is readable' {
        # Guard against a vacuous run: every assertion below reads this text.
        Assert-True ($sourceText.Length -gt 10000) `
            ('src\*.ps1 read as ' + $sourceText.Length + ' characters; the regression patterns below would pass without checking anything')
        Assert-True ($stealthText.Length -gt 1000) `
            ('Invoke-StealthScreen.ps1 read as ' + $stealthText.Length + ' characters')
    }

    It 'no stale Write-ARText helper' {
        # The text helper is Get-ARText; Write-ARText was removed in 5.x.
        Assert-NotMatch -Text $sourceText -Pattern 'Write-ARText' `
            -Message 'src\ calls Write-ARText, which does not exist; the UI would throw on every label'
    }

    It 'no Defender process exclusions' {
        # ExclusionProcess is bypassed by Defender tamper protection and hides
        # the payload from the operator's own tooling.
        Assert-NotMatch -Text ($sourceText + $stealthText) -Pattern 'ExclusionProcess' `
            -Message 'a Defender ExclusionProcess call is back; only ExclusionPath is allowed'
    }

    It 'Pass-the-Hash tracks its temporary account' {
        Assert-Match -Text $sourceText -Pattern '\$script:ARHashUserName' `
            -Message 'nothing tracks the account created by Pass-the-Hash; cleanup cannot remove it'
        Assert-NotMatch -Text $sourceText -Pattern 'ARHashUserCreated' `
            -Message 'the old ARHashUserCreated flag is back; it did not survive a session'
    }

    It 'RDPWrap copies the MSI to the target' {
        Assert-Match -Text $sourceText -Pattern '\$remoteMsi\s*=\s*Copy-ARFileToTarget' `
            -Message 'RDPWrap no longer assigns the copied MSI path; installing from the local path fails on a remote target'
    }

    It 'legacy VNC module delegates to the screen route' {
        # The VNC vendor blob is retired: action 702 is a wrapper around the
        # target-side frame server. Any reference to the old files in src\ means
        # the retired path was restored.
        $vnc = Get-ArFunctionAst -Name 'Invoke-ARModuleVncServer'
        Assert-NotNull $vnc 'Invoke-ARModuleVncServer is missing from src; action 702 has no handler'
        Assert-Match -Text $vnc.Ast.Body.Extent.Text -Pattern '\bInvoke-ARAttackQuickScreen\b' `
            -Message 'Invoke-ARModuleVncServer no longer calls Invoke-ARAttackQuickScreen; it is not a wrapper around the frame-server route'
        foreach ($pattern in @('Invoke-Vnc\b', 'VNCViewer\.exe', 'Invoke-VNCServer\.ps1')) {
            Assert-NotMatch -Text $sourceText -Pattern $pattern `
                -Message ('src\*.ps1 still references /' + $pattern + '/; the retired VNC path is back')
        }
    }

    It 'remote temporary directories are tracked' {
        Assert-Match -Text $sourceText -Pattern '\$script:ARRemoteTempDirs\.Add' `
            -Message 'remote temp directories are created without being tracked; cleanup would leak them on the target'
    }

    It 'remote background jobs are tagged for cleanup' {
        Assert-Match -Text $sourceText -Pattern 'AutoRDPwn_' `
            -Message 'remote jobs are no longer tagged; cleanup cannot find the processes it started'
    }

    It 'Stealth Screen is present and parseable' {
        Assert-FileExists -Path $stealthPath -Message 'Resources\Scripts\Invoke-StealthScreen.ps1 is missing'
        Assert-Equal -Expected 0 -Actual @(Get-ArParseErrors -Path $stealthPath).Count `
            -Message 'Invoke-StealthScreen.ps1 does not parse'
    }
}
