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
        
        [Parameter($false)]
        [switch]$RestartExplorer
    )

    process {
        $regPath = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayNotSIB"
        $entrySize = 1640
        $pathLimit = 520

        # ROT13 核心算法
        $ConvertROT13 = {
            param ([string]$s)
            if ([string]::IsNullOrEmpty($s)) { return "" }
            $cArray = $s.ToCharArray()
            for ($i = 0; $i -lt $cArray.Length; $i++) {
                $code = [int]$cArray[$i]
                if ($code -ge 97 -and $code -le 122) { $cArray[$i] = [char]((($code - 97 + 13) % 26) + 97) }
                elseif ($code -ge 65 -and $code -le 90) { $cArray[$i] = [char]((($code - 65 + 13) % 26) + 65) }
            }
            return -join $cArray
        }

        try {
            $val = Get-ItemProperty -Path $regPath -Name IconStreams -ErrorAction Stop
            [byte[]]$raw = $val.IconStreams
            $modifiedCount = 0

            # 遍历 $1640 字节条目
            for ($offset = 20; $offset -le $raw.Length - $entrySize; $offset += $entrySize) {
                
                # 1. 提取并解密路径区 (0-519 字节)
                $pathSegment = $raw[$offset..($offset + $pathLimit - 1)]
                $pathDecoded = [System.Text.Encoding]::Unicode.GetString($pathSegment).Split("`0")[0]
                $pathDecoded = &$ConvertROT13 $pathDecoded

                # 2. 构建 Scoop 专用的正则表达式
                # 匹配模式示例: ...\apps\hwinfo\8.46-5960\hwinfo64.exe
                # 我们锁定 apps\<AppName>\ 之后的部分
                $pattern = "(?i)apps\\$([regex]::Escape($AppName))\\(?<oldVer>[^\\]+)\\"
                
                if ($pathDecoded -match $pattern) {
                    $oldVer = $Matches['oldVer']
                    
                    # 如果旧版本号与新版本号不同，则执行替换
                    if ($oldVer -ne $NewVersion) {
                        $newPath = $pathDecoded.Replace($oldVer, $NewVersion)
                        $encodedPath = &$ConvertROT13 $newPath
                        $newPathBytes = [System.Text.Encoding]::Unicode.GetBytes($encodedPath)

                        # 3. 物理级原地重写，保护 520 偏移处的 Icon UID
                        for ($j = 0; $j -lt $pathLimit; $j++) { $raw[$offset + $j] = 0 }
                        $copyLen = [Math]::Min($newPathBytes.Length, $pathLimit - 2)
                        [Array]::Copy($newPathBytes, 0, $raw, $offset, $copyLen)

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