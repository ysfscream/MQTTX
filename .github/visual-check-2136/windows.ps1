$ErrorActionPreference = 'Stop'
$out = (Resolve-Path 'visual-results').Path
$checks = New-Object 'System.Collections.Generic.List[object]'
function Check($name, [bool]$pass, $detail) {
    $checks.Add([pscustomobject]@{ name=$name; pass=$pass; detail=$detail })
    ConvertTo-Json -InputObject @($checks.ToArray()) -Depth 12 | Set-Content "$out/windows-checks.json" -Encoding UTF8
    Write-Host "$name : $pass : $($detail | ConvertTo-Json -Compress -Depth 8)"
}
function Attempt($name, [scriptblock]$action) {
    try { $detail = & $action; Check $name $true $detail }
    catch { Check $name $false $_.ToString() }
}
function RegistryEntries {
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        Get-ItemProperty "$root\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*MQTTX*' } | ForEach-Object {
            [pscustomobject]@{ path=$_.PSPath; DisplayName=$_.DisplayName; DisplayIcon=$_.DisplayIcon; InstallLocation=$_.InstallLocation; UninstallString=$_.UninstallString }
        }
    }
}
$uninstaller = $null
$installDir = $null
$desktopLinks = @()
$menuLinks = @()
try {
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    Add-Type -Path "$PSScriptRoot/WindowsIcons.cs" -ReferencedAssemblies System.Drawing,System.Windows.Forms
    [NativeVisual]::Init()
    Check 'environment' $true @{ os=[Environment]::OSVersion.ToString(); user=[Environment]::UserName; interactive=[Environment]::UserInteractive; session=(Get-Process -Id $PID).SessionId; commit=$env:GITHUB_SHA }
    $installers = @(Get-ChildItem 'dist_electron/MQTTX-Setup-*-x64.exe')
    Check 'nsis-x64-package' ($installers.Count -eq 1) @($installers.FullName)
    if ($installers.Count -ne 1) { throw 'Expected exactly one NSIS x64 installer' }
    $installer = $installers[0].FullName
    $install = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru
    Check 'silent-install-exit' ($install.ExitCode -eq 0) @{ exitCode=$install.ExitCode; command="$installer /S" }
    $desktopRoots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) | Select-Object -Unique
    $menuRoots = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms')) | Select-Object -Unique
    $desktopLinks = @($desktopRoots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'MQTTX.lnk' -ErrorAction SilentlyContinue })
    $menuLinks = @($menuRoots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'MQTTX.lnk' -Recurse -ErrorAction SilentlyContinue })
    $shell = New-Object -ComObject WScript.Shell
    $shortcutData = @()
    foreach ($kind in @('desktop','start-menu')) {
        $links = if ($kind -eq 'desktop') { $desktopLinks } else { $menuLinks }
        Check "$kind-shortcut-exists" (@($links).Count -gt 0) @($links.FullName)
        foreach ($link in $links) {
            $lnk = $shell.CreateShortcut($link.FullName)
            $data = [pscustomobject]@{ kind=$kind; path=$link.FullName; TargetPath=$lnk.TargetPath; IconLocation=$lnk.IconLocation }
            $shortcutData += $data
            Check "$kind-shortcut-target-icon" ((Test-Path $data.TargetPath) -and $data.IconLocation -match 'MQTTX.*\.exe') $data
        }
    }
    $registry = @(RegistryEntries)
    Check 'uninstall-registry' ($registry.Count -gt 0 -and @($registry | Where-Object { !$_.DisplayName -or !$_.DisplayIcon }).Count -eq 0) $registry
    $target = $shortcutData | Where-Object { Test-Path $_.TargetPath } | Select-Object -First 1
    if ($target) { $installDir = Split-Path $target.TargetPath }
    if (!$installDir) { $installDir = ($registry | Where-Object InstallLocation | Select-Object -First 1).InstallLocation }
    if (!$installDir) { throw 'Cannot discover installed directory from shortcuts or registry' }
    $exe = Join-Path $installDir 'MQTTX.exe'
    $uninstaller = Join-Path $installDir 'Uninstall MQTTX.exe'
    Check 'installation-directory' (Test-Path $installDir -PathType Container) $installDir
    Check 'installed-executable' (Test-Path $exe -PathType Leaf) $exe
    Check 'uninstaller-executable' (Test-Path $uninstaller -PathType Leaf) $uninstaller
    foreach ($data in $shortcutData) {
        Check "$($data.kind)-installed-target" ($data.TargetPath -ieq $exe) $data
    }
    $sources = [ordered]@{ installer=$installer; installed=$exe; uninstaller=$uninstaller }
    if ($desktopLinks.Count) { $sources['desktop-shortcut'] = $desktopLinks[0].FullName }
    if ($menuLinks.Count) { $sources['start-menu-shortcut'] = $menuLinks[0].FullName }
    foreach ($name in $sources.Keys) {
        foreach ($size in @(16,32,48,256)) {
            Attempt "shell-icon-$name-$size" { [NativeVisual]::ShellIcon($sources[$name], $size, "$out/windows-$name-$size.png") }
        }
    }
    # The hosted runner's interactive Explorer session supplies the real desktop/taskbar.
    Get-Process MQTTX -ErrorAction SilentlyContinue | Stop-Process -Force
    $app = Start-Process -FilePath $exe -WorkingDirectory $installDir -PassThru -RedirectStandardOutput "$out/windows-app-stdout.log" -RedirectStandardError "$out/windows-app-stderr.log"
    $deadline = (Get-Date).AddSeconds(60)
    $window = $null
    do {
        $window = Get-Process MQTTX -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and [NativeVisual]::IsWindowVisible($_.MainWindowHandle) -and $_.Path -ieq $exe } | Select-Object -First 1
        if (!$window) { Start-Sleep -Seconds 1 }
    } until ($window -or (Get-Date) -gt $deadline)
    Check 'installed-main-window-visible' ([bool]$window) @{ launchedPath=$exe; launchedPID=$app.Id; windowPID=$window.Id; handle=[string]$window.MainWindowHandle; title=$window.MainWindowTitle }
    if ($window) {
        $hwnd = $window.MainWindowHandle
        [NativeVisual]::ShowWindow($hwnd,9) | Out-Null
        [NativeVisual]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Seconds 10
        Attempt 'full-desktop-screenshot' { [NativeVisual]::Capture("$out/windows-fullscreen.png",[IntPtr]::Zero) }
        Attempt 'main-window-screenshot' { [NativeVisual]::Capture("$out/windows-main-window.png",$hwnd) }
        Attempt 'window-icon-small' { [NativeVisual]::WindowIcon($hwnd,$true,"$out/windows-window-icon-small.png") }
        Attempt 'window-icon-big' { [NativeVisual]::WindowIcon($hwnd,$false,"$out/windows-window-icon-big.png") }
    }
    $desktopShell = New-Object -ComObject Shell.Application
    $desktopShell.MinimizeAll()
    Start-Sleep -Seconds 4
    Attempt 'explorer-shortcut-screenshot' { [NativeVisual]::Capture("$out/windows-desktop-shortcut.png",[IntPtr]::Zero) }
} catch {
    Check 'harness-completed' $false $_.ToString()
    $_ | Out-String | Set-Content "$out/windows-error.log"
} finally {
    Get-Process MQTTX -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($uninstaller -and (Test-Path $uninstaller)) {
        try {
            $uninstall = Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait -PassThru
            Check 'silent-uninstall-exit' ($uninstall.ExitCode -eq 0) @{ exitCode=$uninstall.ExitCode; command="$uninstaller /S" }
            $deadline = (Get-Date).AddSeconds(60)
            do {
                $remainingRegistry = @(RegistryEntries)
                $remainingLinks = @(@($desktopLinks) + @($menuLinks) | Where-Object { Test-Path $_.FullName })
                $remainingDir = Test-Path $installDir
                if (!$remainingDir -and !$remainingLinks.Count -and !$remainingRegistry.Count) { break }
                Start-Sleep -Seconds 2
            } until ((Get-Date) -gt $deadline)
            Check 'uninstall-directory-removed' (!$remainingDir) $installDir
            Check 'uninstall-desktop-shortcut-removed' (@($desktopLinks | Where-Object { Test-Path $_.FullName }).Count -eq 0) @($desktopLinks.FullName)
            Check 'uninstall-start-menu-shortcut-removed' (@($menuLinks | Where-Object { Test-Path $_.FullName }).Count -eq 0) @($menuLinks.FullName)
            Check 'uninstall-registry-removed' ($remainingRegistry.Count -eq 0) $remainingRegistry
        } catch { Check 'uninstall-completed' $false $_.ToString() }
    } else { Check 'silent-uninstall-exit' $false 'No installed uninstaller was discovered' }
}
if (@($checks | Where-Object { !$_.pass }).Count) { exit 1 }
