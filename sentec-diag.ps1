$ErrorActionPreference = 'SilentlyContinue'
$R = "$env:TEMP\sentec-diag.txt"
$W = "$env:TEMP\sentec-diag-wa.txt"
$nl = "`n"
$full = @()
$wa = @()

# --- TCP latency helper (cloudping-style) ---
function Measure-TcpLatency {
    param([string]$Host_, [int]$Port = 443, [int]$Count = 3)
    $results = @()
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $tcp.Connect($Host_, $Port)
            $sw.Stop()
            $results += $sw.ElapsedMilliseconds
            $tcp.Close()
        } catch {
            # connection failed, skip
        }
        if ($i -lt ($Count - 1)) { Start-Sleep -Milliseconds 200 }
    }
    if ($results.Count -gt 0) {
        $avg = [math]::Round(($results | Measure-Object -Average).Average)
        $mn  = ($results | Measure-Object -Minimum).Minimum
        $mx  = ($results | Measure-Object -Maximum).Maximum
        return @{ Avg = $avg; Min = $mn; Max = $mx; OK = $true; Samples = $results.Count }
    }
    return @{ OK = $false }
}

Write-Host '  [1/11] Computer identity...'
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor
$cs = Get-CimInstance Win32_ComputerSystem
$boot = $os.LastBootUpTime
$up = (Get-Date) - $boot
$upStr = "$($up.Days)d $($up.Hours)h $($up.Minutes)m"

$full += '===================================================='
$full += ' SENTEC PMS - LOCAL SYSTEM DIAGNOSTICS'
$full += " Generated: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
$full += '================================================='
$full += ''
$full += "Hostname: $env:COMPUTERNAME"
$full += "Username: $env:USERNAME"
$full += "Domain: $env:USERDOMAIN"
$full += "OS: $($os.Caption) Build $($os.BuildNumber)"
$full += "Arch: $($os.OSArchitecture)"
$full += "Model: $($cs.Manufacturer) $($cs.Model)"
$full += "Uptime: $upStr"
$full += ''

$wa += "*SENTEC LOCAL DIAGNOSTICS*"
$wa += "$(Get-Date -Format 'dd/MM/yyyy HH:mm')"
$wa += ''
$wa += "*IDENTITY*"
$wa += "- Hostname: $env:COMPUTERNAME"
$wa += "- User: $env:USERDOMAIN\$env:USERNAME"
$wa += "- OS: $($os.Caption)"
$wa += "- Model: $($cs.Model)"
$wa += "- Uptime: $upStr"
$wa += ''

Write-Host '  [2/11] CPU and temperature...'
$full += "CPU: $($cpu.Name.Trim())"
$full += "Cores: $($cpu.NumberOfCores) / Threads: $($cpu.NumberOfLogicalProcessors)"
$full += "Max Clock: $($cpu.MaxClockSpeed) MHz"
$full += "CPU Load: $($cpu.LoadPercentage)%"

$wa += "*HARDWARE*"
$wa += "- CPU: $($cpu.Name.Trim())"
$wa += "- Cores/Threads: $($cpu.NumberOfCores)/$($cpu.NumberOfLogicalProcessors) @ $($cpu.MaxClockSpeed)MHz"
$wa += "- CPU Load: $($cpu.LoadPercentage)%"

try {
    $tz = Get-CimInstance MSAcpi_ThermalZoneTemperature -Namespace root/wmi -ErrorAction Stop | Select-Object -First 1
    $tc = [math]::Round(($tz.CurrentTemperature / 10) - 273.15, 1)
    $fl = if ($tc -gt 85) { 'CRITICAL' } elseif ($tc -gt 75) { 'HOT' } else { 'OK' }
    $ti = if ($tc -gt 85) { "[CRITICAL]" } elseif ($tc -gt 75) { "[HOT]" } else { "[OK]" }
    $full += "CPU Temp: ${tc}C [$fl]"
    $wa += "- Temp: ${tc}C $ti"
} catch {
    $full += 'CPU Temp: Requires admin (run as Administrator)'
    $wa += "- Temp: N/A (run as Admin)"
}
$full += ''

Write-Host '  [3/11] Memory...'
$tGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$fGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$uP = [math]::Round(($tGB - $fGB) / $tGB * 100)
$full += "RAM: ${tGB}GB total, ${fGB}GB free (${uP}% used)"
$wa += "- RAM: ${tGB}GB total, ${fGB}GB free (${uP}%)"

Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    $g = [math]::Round($_.Capacity / 1GB)
    $t = switch ($_.SMBIOSMemoryType) { 20 { 'DDR3' } 24 { 'DDR4' } 26 { 'DDR4' } 34 { 'DDR5' } default { 'DDR?' } }
    $full += "  ${g}GB $t @ $($_.Speed)MHz ($($_.DeviceLocator))"
    $wa += "    ${g}GB $t @ $($_.Speed)MHz"
}
$full += ''

Write-Host '  [4/11] Storage and GPU...'
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $f = [math]::Round($_.FreeSpace / 1GB); $s = [math]::Round($_.Size / 1GB)
    $p = if ($s -gt 0) { [math]::Round(($s - $f) / $s * 100) } else { 0 }
    $full += "$($_.DeviceID) ${f}GB free / ${s}GB total (${p}% used)"
    $wa += "- Disk $($_.DeviceID) ${f}GB free / ${s}GB"
}
Get-CimInstance Win32_DiskDrive | ForEach-Object {
    $full += "  Disk: $($_.Model) ($([math]::Round($_.Size/1GB))GB)"
}
Get-CimInstance Win32_VideoController | ForEach-Object {
    $full += "GPU: $($_.Name) (Driver: $($_.DriverVersion))"
    $wa += "- GPU: $($_.Name)"
}
$full += ''
$wa += ''

Write-Host '  [5/11] Network...'
$wa += "*NETWORK*"
Get-NetAdapter | Where-Object Status -eq Up | ForEach-Object {
    $full += "Adapter: $($_.Name) ($($_.InterfaceDescription))"
    $full += "  Link Speed: $($_.LinkSpeed)"
    $full += "  MAC: $($_.MacAddress)"
    $wa += "- $($_.Name) ($($_.LinkSpeed))"
    $wa += "  MAC: $($_.MacAddress)"
    $ip = Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ip) {
        $full += "  Local IP: $($ip.IPAddress)/$($ip.PrefixLength)"
        $wa += "  IP: $($ip.IPAddress)/$($ip.PrefixLength)"
    }
    $gw = Get-NetRoute -InterfaceIndex $_.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if ($gw) {
        $full += "  Gateway: $($gw.NextHop)"
        $wa += "  GW: $($gw.NextHop)"
    }
}
$dns = Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object ServerAddresses | Select-Object -ExpandProperty ServerAddresses -Unique
$full += "DNS: $($dns -join ', ')"
$wa += "- DNS: $($dns -join ', ')"
$full += ''
$wa += ''

Write-Host '  [6/11] DNS resolution...'
foreach ($h in @('apse1.pms.sentec.io', 'apse1.api.pms.sentec.io', 'google.com')) {
    try {
        $r = Resolve-DnsName $h -Type A -DnsOnly -ErrorAction Stop | Select-Object -First 1
        $full += "$h -> $($r.IPAddress) [OK]"
    } catch {
        $full += "$h -> FAILED"
    }
}
$full += ''

Write-Host '  [7/11] Ping tests...'
$wa += "*PING*"
foreach ($h in @('google.com', 'cloudflare.com', 'apse1.pms.sentec.io', 'apse1.api.pms.sentec.io')) {
    Write-Host "    Pinging $h..."
    $p = Test-Connection -ComputerName $h -Count 5 -ErrorAction SilentlyContinue
    if ($p) {
        $avg = [math]::Round(($p | Measure-Object -Property Latency -Average).Average)
        $mn = ($p | Measure-Object -Property Latency -Minimum).Minimum
        $mx = ($p | Measure-Object -Property Latency -Maximum).Maximum
        $full += "$h avg=${avg}ms min=${mn}ms max=${mx}ms loss=0/5"
        $wa += "- ${h}: ${avg}ms [OK]"
    } else {
        $full += "$h FAILED (100% loss)"
        $wa += "- ${h}: FAILED [X]"
    }
}
$full += ''
$wa += ''

Write-Host '  [8/11] AWS Region Latency (cloudping-style)...'
$full += '--- AWS REGION LATENCY (TCP 443 to DynamoDB endpoints) ---'
$wa += "*AWS LATENCY*"

# Regions to test: Sentec region + nearby comparisons
$awsRegions = [ordered]@{
    'ap-southeast-1' = 'Singapore [SENTEC]'
    'ap-southeast-2' = 'Sydney'
    'ap-northeast-1' = 'Tokyo'
    'ap-south-1'     = 'Mumbai'
    'us-west-2'      = 'Oregon'
    'eu-west-1'      = 'Ireland'
}

foreach ($region in $awsRegions.GetEnumerator()) {
    $endpoint = "dynamodb.$($region.Key).amazonaws.com"
    $label = $region.Value
    Write-Host "    Testing $($region.Key) ($label)..."
    $result = Measure-TcpLatency -Host_ $endpoint -Port 443 -Count 5

    if ($result.OK) {
        $tag = if ($result.Avg -lt 80) { '[OK]' }
               elseif ($result.Avg -lt 150) { '[WARN]' }
               else { '[SLOW]' }

        $full += "$($region.Key) ($label): avg=$($result.Avg)ms min=$($result.Min)ms max=$($result.Max)ms $tag"

        $waTag = if ($result.Avg -lt 80) { '[OK]' }
                 elseif ($result.Avg -lt 150) { '[~]' }
                 else { '[!]' }
        if ($region.Key -eq 'ap-southeast-1') {
            $wa += "- *$($region.Key)*: $($result.Avg)ms $waTag << SENTEC"
        } else {
            $wa += "- $($region.Key): $($result.Avg)ms $waTag"
        }
    } else {
        $full += "$($region.Key) ($label): FAILED (TCP connect failed)"
        $wa += "- $($region.Key): FAILED [X]"
    }
}
$full += ''
$wa += ''

Write-Host '  [9/11] Traceroute (up to 60s)...'
$full += '--- TRACEROUTE to apse1.pms.sentec.io ---'
$trace = & tracert -d -w 2000 -h 20 apse1.pms.sentec.io 2>$null
if ($trace) { $full += $trace }
$full += ''

Write-Host '  [10/11] Browsers...'
$wa += "*BROWSERS*"
$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
)
foreach ($p in $chromePaths) {
    if (Test-Path $p) {
        $v = (Get-Item $p).VersionInfo.ProductVersion
        $full += "Chrome: v$v"
        $wa += "- Chrome: v$v"
        break
    }
}
$edgePaths = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
)
foreach ($p in $edgePaths) {
    if (Test-Path $p) {
        $v = (Get-Item $p).VersionInfo.ProductVersion
        $full += "Edge: v$v"
        $wa += "- Edge: v$v"
        break
    }
}
$cp = Get-Process -Name chrome -ErrorAction SilentlyContinue
if ($cp) {
    $cm = [math]::Round(($cp | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    $full += "Chrome: $($cp.Count) processes, ${cm}MB"
    $wa += "- Chrome: $($cp.Count) tabs, ${cm}MB"
}
$full += ''

Write-Host '  [11/11] Processes and AV...'
$wa += ''
$wa += "*TOP 5 PROCESSES*"
$i = 0
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 | ForEach-Object {
    $mb = [math]::Round($_.WorkingSet64 / 1MB)
    $full += "$($_.ProcessName): ${mb}MB"
    if ($i -lt 5) { $wa += "- $($_.ProcessName): ${mb}MB" }
    $i++
}
$full += ''
$wa += ''
$wa += "*AV*"
try {
    Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object {
        $full += "AV: $($_.displayName)"
        $wa += "- $($_.displayName)"
    }
} catch {
    $wa += "- N/A"
}
$wa += ''
$wa += "From: *$env:COMPUTERNAME*"
$full += '===================================================='
$full += " End - $env:COMPUTERNAME - $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
$full += '===================================================='

# Save files
$full -join "`n" | Set-Content -Path $R -Encoding UTF8
$wa -join "`n" | Set-Content -Path $W -Encoding UTF8
$wa -join "`n" | Set-Clipboard

Write-Host ''
Write-Host '  Done! Report copied to clipboard.'
