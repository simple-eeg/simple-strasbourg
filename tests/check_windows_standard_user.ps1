# Run only on a disposable Windows CI runner: create and remove a local user.
$ErrorActionPreference = 'Stop'
$userName = 'simple' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$passwordText = [guid]::NewGuid().ToString('N') + 'aA1!'
Write-Output "::add-mask::$passwordText"
$password = ConvertTo-SecureString $passwordText -AsPlainText -Force
$checkRoot = Join-Path $env:PUBLIC ('simple-link-test-' + [guid]::NewGuid().ToString('N'))
$account = $null
try {
    $account = New-LocalUser -Name $userName -Password $password
    $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
    Add-LocalGroupMember -Group $usersGroup -Member $account
    New-Item -ItemType Directory -Path $checkRoot | Out-Null
    & icacls.exe $checkRoot /grant ('*' + $account.SID.Value + ':(OI)(CI)M') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not grant access to the CI fixture folder.' }
    $checker = Join-Path $checkRoot 'check_windows_hard_links.py'
    Copy-Item (Join-Path $PSScriptRoot 'check_windows_hard_links.py') $checker
    $python = (Get-Command python).Source
    $log = Join-Path $checkRoot 'result.txt'
    $runner = Join-Path $checkRoot 'run.cmd'
    @"
@echo off
set "TEMP=$checkRoot"
set "TMP=$checkRoot"
set "SIMPLE_TEST_REQUIRE_NONADMIN=1"
"$python" "$checker" > "$log" 2>&1
exit /b %ERRORLEVEL%
"@ | Set-Content -Path $runner -Encoding ascii
    $credential = [pscredential]::new("$env:COMPUTERNAME\$userName", $password)
    $process = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" `
        -ArgumentList "/d /c `"$runner`"" -Credential $credential `
        -WorkingDirectory $checkRoot -LoadUserProfile -Wait -PassThru
    if (Test-Path $log) { Get-Content $log }
    if ($process.ExitCode -ne 0) {
        throw "Standard-user file-link check failed with exit code $($process.ExitCode)."
    }
} finally {
    if ($null -ne $account) { Remove-LocalUser -Name $userName }
    if (Test-Path $checkRoot) { Remove-Item $checkRoot -Recurse -Force }
}
