# 检测 PowerShell 版本，要求 PS7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "此脚本需要 PowerShell 7 或更高版本，当前版本: $($PSVersionTable.PSVersion.ToString())"
    Write-Error "请从 https://aka.ms/powershell 下载并安装 PowerShell 7"
    
    # 定义空函数，避免调用方报错
    function Update-ScoopTrayIconPath { }
    return
}

# --- GUID 已知文件夹路径解析 ---
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

    $pathElements = $Path -split '[\\/]'
    if ($guid = $pathElements[0] -as [Guid]) {
        $pathElements[0] = [KnownFolder]::GetPath($guid)
        $Path = [System.IO.Path]::Combine($pathElements)
    }
    $Path
}

# --- ROT13 编解码 ---
function Convert-CASHybridText {
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

function Update-ScoopTrayIconPath {
    <#
    .DESCRIPTION
        专为 Scoop 软件设计的托盘路径修复函数。
        自动匹配路径模式: ...\apps\<AppName>\<OldVersion>\<ExeName>
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
        $entrySize = 1640
        $pathLimit = 520

        try {
            $val = Get-ItemProperty -Path $regPath -Name IconStreams -ErrorAction Stop
            [byte[]]$raw = $val.IconStreams
            $modifiedCount = 0

            # 预编译正则表达式
            $pattern = "(?i)apps\\$([regex]::Escape($AppName))\\(?<oldVer>[^\\]+)\\"
            $regex = [regex]::new($pattern)

            # 遍历 1640 字节条目
            for ($offset = 20; $offset -le $raw.Length - $entrySize; $offset += $entrySize) {
                
                # 1. 提取并解密路径区 (0-519 字节)
                $pathSegment = $raw[$offset..($offset + $pathLimit - 1)]
                $pathDecoded = [System.Text.Encoding]::Unicode.GetString($pathSegment).Split("`0")[0]
                $pathDecoded = Convert-CASHybridText $pathDecoded

                # 解析 GUID 已知文件夹路径
                $resolvedPath = Resolve-KnownFolder $pathDecoded

                # 2. 使用预编译正则匹配
                if ($regex.Match($resolvedPath) -match $pattern) {
                    $oldVer = $Matches['oldVer']
                    
                    # 如果旧版本号与新版本号不同，则执行替换
                    if ($oldVer -ne $NewVersion) {
                        $newPath = $resolvedPath.Replace($oldVer, $NewVersion)
                        $encodedPath = Convert-CASHybridText $newPath
                        $newPathBytes = [System.Text.Encoding]::Unicode.GetBytes($encodedPath)

                        # 3. 逐字节写入路径区，保护 520 偏移后的 Icon UID 等字段
                        for ($i = 0; $i -lt $pathLimit; $i++) {
                            if ($i -lt $newPathBytes.Length) {
                                $raw[$offset + $i] = $newPathBytes[$i]
                            } else {
                                $raw[$offset + $i] = 0
                            }
                        }

                        Write-Host "[Scoop Fix] $AppName: $oldVer -> $NewVersion" -ForegroundColor Green
                        $modifiedCount++
                    }
                }
            }

            if ($modifiedCount -gt 0) {
                Set-ItemProperty -Path $regPath -Name IconStreams -Value $raw
                if ($RestartExplorer) { Stop-Process -Name explorer -Force }
            }
        }
        catch {
            Write-Error "Scoop 路径修复失败: $($_.Exception.Message)"
        }
    }
}
