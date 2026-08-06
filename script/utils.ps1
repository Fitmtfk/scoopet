# --- GUID Known Folder Path Resolution ---
function Resolve-KnownFolder {
    [CmdletBinding()]
    param (
        [string]$Path
    )

    begin {
        if (-not ('KnownFolder' -as [Type])) {
            Add-Type -TypeDefinition '
            using System;
            using System.Runtime.InteropServices;
            
            internal class UnsafeNativeMethods
            {
                [DllImport("shell32.dll")]
                internal static extern int SHGetKnownFolderPath(
                    [MarshalAs(UnmanagedType.LPStruct)] Guid rfid,
                    uint dwFlags,
                    IntPtr hToken,
                    out IntPtr ppszPath
                );
            }
            
            public class KnownFolder {
                public static string GetPath(Guid guid)
                {
                    IntPtr ppszPath = IntPtr.Zero;
                    UnsafeNativeMethods.SHGetKnownFolderPath(
                        guid, 0, IntPtr.Zero, out ppszPath
                    );
                    string path = Marshal.PtrToStringUni(ppszPath);
                    Marshal.FreeCoTaskMem(ppszPath);
                    return path;
                }
            }
            '
        }
    }

    process {
        $pathElements = $Path -split '[\\/]'
        if ($guid = $pathElements[0] -as [Guid]) {
            $pathElements[0] = [KnownFolder]::GetPath($guid)
            $Path = [System.IO.Path]::Combine($pathElements)
        }
        $Path
    }
}

# --- ROT13 Encoding/Decoding ---
function Convert-HybridText {
    param ([string]$InputString)
    if ([string]::IsNullOrEmpty($InputString)) { return "" }
    $chars = $InputString.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = [int]$chars[$i]
        if ($c -ge 97 -and $c -le 122) { $chars[$i] = [char]((($c - 97 + 13) % 26) + 97) }
        elseif ($c -ge 65 -and $c -le 90) { $chars[$i] = [char]((($c - 65 + 13) % 26) + 65) }
    }
    return -join $chars
}

# --- Execute tray icon path fix (wrapped in function for PS5 compatibility) ---
function FixTrayIcon {
    param (
        [string]$regPath,
        [byte[]]$raw,
        [string]$AppName,
        [string]$NewVersion,
        [int]$entrySize,
        [int]$pathLimit,
        [switch]$RestartExplorer
    )

    $modifiedCount = 0
    $escapedAppName = [regex]::Escape($AppName)
    $pattern = "(?i)apps\\$escapedAppName\\(?<oldVer>[^\\]+)\\"

    for ($offset = 20; $offset + $entrySize -le $raw.Length; $offset += $entrySize) {
        $pathSegment = $raw[$offset..($offset + $pathLimit - 1)]
        $pathDecoded = [System.Text.Encoding]::Unicode.GetString($pathSegment).Split("`0")[0]
        $pathDecoded = Convert-HybridText $pathDecoded
        $resolvedPath = Resolve-KnownFolder $pathDecoded

        if ($resolvedPath -match $pattern) {
            $oldVer = $Matches['oldVer']
            if ($oldVer -ne $NewVersion) {
                $newPath = $resolvedPath.Replace($oldVer, $NewVersion)
                $encodedPath = Convert-HybridText $newPath
                $newPathBytes = [System.Text.Encoding]::Unicode.GetBytes($encodedPath)

                for ($i = 0; $i -lt $pathLimit; $i++) {
                    if ($i -lt $newPathBytes.Length) {
                        $raw[$offset + $i] = $newPathBytes[$i]
                    } else {
                        $raw[$offset + $i] = 0
                    }
                }

                Write-Host "[Scoop Fix] ${AppName}: ${oldVer} -> ${NewVersion}" -ForegroundColor Green
                $modifiedCount++
            }
        }
    }

    if ($modifiedCount -gt 0) {
        Set-ItemProperty -Path $regPath -Name IconStreams -Value $raw
        if ($RestartExplorer) { Stop-Process -Name explorer -Force }
    }
}

function Update-ScoopTrayIconPath {
    <#
    .DESCRIPTION
        Tray icon path fix function designed for Scoop software.
        Auto-matches path pattern: ...\apps\<AppName>\<OldVersion>\<ExeName>
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$AppName,
        
        [Parameter(Mandatory=$true)]
        [string]$NewVersion,
        
        [Parameter()]
        [switch]$RestartExplorer
    )

    process {
        $regPath = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotSIB"
        
        # Check if TrayNotSIB registry exists (created by stratallback taskbar optimization software)
        if (-not (Test-Path $regPath)) {
            Write-Host "No need to update tray icon path: TrayNotSIB registry not found"
            return
        }

        $entrySize = 1640
        $pathLimit = 520

        $val = Get-ItemProperty -Path $regPath -Name IconStreams -ErrorAction SilentlyContinue
        if (-not $val) {
            Write-Error "IconStreams registry value not found"
            return
        }
        FixTrayIcon -regPath $regPath -raw $val.IconStreams -AppName $AppName -NewVersion $NewVersion -entrySize $entrySize -pathLimit $pathLimit -RestartExplorer:$RestartExplorer -ErrorAction Stop
    }
}
Write-Host ""