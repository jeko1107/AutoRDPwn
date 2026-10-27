# Tests\Parse.Tests.ps1
#
# Contract: every .ps1 on disk parses. Nothing is executed. The generated build
# in _sandbox\gen.ps1 is included when it exists, so a build that emits broken
# PowerShell is caught here instead of at runtime.

Describe 'parse' {

    $files = @(Get-ArTestPowerShellFiles)
    $sources = @($files | Where-Object { $_.RelativePath -like 'src\*' })

    It 'repo contains the expected source parts' {
        $expected = @('00-header.ps1', '10-tui.ps1', '20-runtime.ps1', '30-attacks.ps1', '40-modules.ps1', '50-main.ps1')
        Assert-SetEqual -Expected $expected -Actual @($sources | ForEach-Object { $_.Name }) `
            -Message 'src\ does not contain the six build parts; Build.ps1 will fail'
    }

    foreach ($file in $files) {
        $label = $file.RelativePath
        It ('parses ' + $label) {
            $errors = @(Get-ArParseErrors -Path $file.FullName)
            if ($errors.Count -eq 0) { return }
            $detail = @($errors | Select-Object -First 5 | ForEach-Object {
                    '{0}:{1}:{2}: {3}' -f $label, $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
                }) -join [Environment]::NewLine + '      '
            throw ("{0} parse error(s) in {1}`n      {2}" -f $errors.Count, $label, $detail)
        }
    }

    It 'generated sandbox build parses' {
        # The runner builds this before tests run; a missing file means the build
        # step in Run-Tests.ps1 stopped producing it.
        Assert-FileExists -Path $script:ArTestGenPath -Message 'the runner did not produce _sandbox\gen.ps1'
        $errors = @(Get-ArParseErrors -Path $script:ArTestGenPath)
        if ($errors.Count -eq 0) { return }
        $detail = @($errors | Select-Object -First 5 | ForEach-Object {
                'gen.ps1:{0}: {1}' -f $_.Extent.StartLineNumber, $_.Message
            }) -join [Environment]::NewLine + '      '
        throw ("generated build has {0} parse error(s)`n      {1}" -f $errors.Count, $detail)
    }
}
