param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$parts = @(
    'src\00-header.ps1',
    'src\10-tui.ps1',
    'src\20-runtime.ps1',
    'src\30-attacks.ps1',
    'src\40-modules.ps1',
    'src\50-main.ps1'
)
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $root 'AutoRDPwn.ps1' }
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $root $OutputPath }

$builder = New-Object System.Text.StringBuilder
foreach ($part in $parts) {
    $path = Join-Path $root $part
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing source part: $part" }
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw ("Parser error in {0}: {1}" -f $part, $errors[0].Message)
    }
    $partContent = (Get-Content -LiteralPath $path -Raw).TrimEnd("`r", "`n")
    $null = $builder.AppendLine('')
    $null = $builder.AppendLine($partContent)
}

$content = $builder.ToString()
$temporary = $OutputPath + '.tmp'
$encoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($temporary, $content, $encoding)
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($temporary, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    throw ("Parser error in generated file: {0}" -f $errors[0].Message)
}
Move-Item -LiteralPath $temporary -Destination $OutputPath -Force
Write-Host ("Built {0} ({1} bytes)" -f $OutputPath, (Get-Item -LiteralPath $OutputPath).Length) -ForegroundColor Green
