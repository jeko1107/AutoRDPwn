# Tests\Localization.Tests.ps1
#
# Contract: one key set, seven languages. A key added to English must exist in
# every other file, and a Get-ARText reference in src\ must resolve.
#
# The key count itself is not pinned: adding txt155 to all eight files is a
# normal change. Only divergence is a failure.

function Get-ArLanguageKeys {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    return @([regex]::Matches($text, '(?m)^\s*\$txt(\d+)\s*=') |
        ForEach-Object { 'txt' + $_.Groups[1].Value } | Sort-Object -Unique)
}

Describe 'localization' {

    $languageDir = Join-Path $script:ArTestRoot 'Resources\Languages'
    $files = @(Get-ChildItem -LiteralPath $languageDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)

    It 'ships the seven language files' {
        Assert-SetEqual -Expected @('English.ps1', 'French.ps1', 'German.ps1', 'Italian.ps1', 'Portuguese.ps1', 'Russian.ps1', 'Spanish.ps1') `
            -Actual @($files | ForEach-Object { $_.Name }) -Message 'the language set changed; Initialize-ARLanguage maps seven locales'
    }

    It 'ships every language file as UTF-8 with BOM' {
        # Get-Content decodes BOM-less files with the ANSI code page on Windows
        # PowerShell 5.1, which mangles the accented strings at import time.
        foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            Assert-True ($bytes.Length -ge 3) ('{0} is shorter than a BOM; the import would read it as ANSI' -f $file.Name)
            Assert-True (($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) `
                ('{0} is not UTF-8 with BOM; Windows PowerShell 5.1 decodes it as ANSI and the UI shows mojibake' -f $file.Name)
        }
    }

    if ($files.Count -gt 0) {
        $englishKeys = @(Get-ArLanguageKeys -Path (Join-Path $languageDir 'English.ps1'))
        Assert-True ($englishKeys.Count -gt 0) 'English.ps1 defines no $txt keys'

        foreach ($file in $files) {
            $languageFile = $file
            It ('key set matches English: ' + $languageFile.Name) {
                $keys = @(Get-ArLanguageKeys -Path $languageFile.FullName)
                Assert-SetEqual -Expected $englishKeys -Actual $keys `
                    -Message ('{0} has a different key set than English.ps1; the UI falls back to the English default' -f $languageFile.Name)
            }
        }

        It 'every text key used by src exists' {
            # A key that src\ requests and English.ps1 does not define renders the
            # caller's default, so a missing translation silently drops the label.
            $references = New-Object System.Collections.ArrayList
            foreach ($path in @(Get-ArSourceFilePaths)) {
                $text = Get-Content -LiteralPath $path -Raw
                foreach ($match in [regex]::Matches($text, "Get-ARText\s+'?(txt\d+)")) {
                    $null = $references.Add($match.Groups[1].Value)
                }
            }
            $missing = @(@($references | Sort-Object -Unique) | Where-Object { $englishKeys -notcontains $_ })
            if ($missing.Count -eq 0) { return }
            throw ('src\ references {0} text key(s) that English.ps1 does not define: {1}' -f $missing.Count, ($missing -join ', '))
        }
    }
}
