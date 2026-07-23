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
        } catch {}
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

Write-Host '  [1/12] Computer identity...'
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

Write-Host '  [2/12] CPU and temperature...'
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

Write-Host '  [3/12] Memory...'
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

Write-Host '  [4/12] Storage and GPU...'
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

Write-Host '  [5/12] Network...'
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

Write-Host '  [6/12] ISP detection...'
$full += '--- ISP / PUBLIC IP ---'
$wa += "*ISP*"
$ispName = ''; $ispOrg = ''; $ispAs = ''; $ispCity = ''; $ispCountry = ''; $pubIp = ''

# Known SEA ISP DNS servers for fallback detection
$knownIspDns = @{
    # Indonesia
    '202.134.0.155' = 'Telkom (ID)';  '202.134.1.10'  = 'Telkom (ID)'
    '202.134.0.61'  = 'Telkom (ID)';  '203.130.196.5' = 'Telkom (ID)'
    '202.155.0.10'  = 'Indosat (ID)'; '202.155.0.15'  = 'Indosat (ID)'
    '202.152.254.245'='Indosat (ID)'; '202.155.46.66' = 'Indosat (ID)'
    '203.142.82.222' = 'Biznet (ID)'; '203.142.83.222' = 'Biznet (ID)'
    '112.215.36.150' = 'XL (ID)';     '112.215.36.154' = 'XL (ID)'
    '203.153.132.1'  = 'LinkNet/FirstMedia (ID)'
    '103.86.96.2'    = 'MyRepublic (ID)'; '103.86.96.3' = 'MyRepublic (ID)'
    # Malaysia
    '1.9.1.1'        = 'TM/Unifi (MY)'; '210.187.130.63' = 'TM/Unifi (MY)'
    '210.187.130.60' = 'TM/Unifi (MY)'
    '202.188.0.133'  = 'Maxis (MY)';   '202.188.1.5'   = 'Maxis (MY)'
    '211.25.206.147' = 'TIME (MY)';     '124.217.233.1' = 'TIME (MY)'
    '218.208.28.34'  = 'Digi (MY)';    '218.208.28.18' = 'Digi (MY)'
}

# Try primary API: ip-api.com (no key needed, JSON)
try {
    $geo = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=query,isp,org,as,city,regionName,country,countryCode' -TimeoutSec 5 -ErrorAction Stop
    $pubIp      = $geo.query
    $ispName    = $geo.isp
    $ispOrg     = $geo.org
    $ispAs      = $geo.as
    $ispCity    = $geo.city
    $ispCountry = "$($geo.country) ($($geo.countryCode))"

    $full += "Public IP: $pubIp"
    $full += "ISP: $ispName"
    $full += "Org: $ispOrg"
    $full += "ASN: $ispAs"
    $full += "Location: $ispCity, $ispCountry"

    $wa += "- IP: $pubIp"
    $wa += "- ISP: *$ispName*"
    if ($ispCity) { $wa += "- Location: $ispCity, $($geo.countryCode)" }
} catch {
    # Fallback: try ipinfo.io
    try {
        $geo2 = Invoke-RestMethod -Uri 'https://ipinfo.io/json' -TimeoutSec 5 -ErrorAction Stop
        $pubIp   = $geo2.ip
        $ispName = $geo2.org
        $ispCity = $geo2.city
        $ispCountry = $geo2.country

        $full += "Public IP: $pubIp"
        $full += "ISP: $ispName"
        $full += "Location: $ispCity, $ispCountry"

        $wa += "- IP: $pubIp"
        $wa += "- ISP: *$ispName*"
        if ($ispCity) { $wa += "- Location: $ispCity, $ispCountry" }
    } catch {
        # Last fallback: detect from DNS servers
        $detectedIsp = ''
        foreach ($d in $dns) {
            if ($knownIspDns.ContainsKey($d)) {
                $detectedIsp = $knownIspDns[$d]
                break
            }
        }
        if ($detectedIsp) {
            $full += "ISP (from DNS): $detectedIsp"
            $wa += "- ISP (DNS): *$detectedIsp*"
            $ispName = $detectedIsp
        } else {
            $full += "ISP: Could not detect (API blocked)"
            $wa += "- ISP: N/A (blocked)"
        }
    }
}

# DNS-based ISP hint (always show if matched, even if API worked)
foreach ($d in $dns) {
    if ($knownIspDns.ContainsKey($d)) {
        $hint = $knownIspDns[$d]
        $full += "DNS hint: $d -> $hint"
        if (-not $ispName.Contains($hint.Split(' ')[0])) {
            $wa += "- DNS hint: $hint"
        }
        break
    }
}
$full += ''
$wa += ''

Write-Host '  [7/12] DNS resolution...'
foreach ($h in @('apse1.pms.sentec.io', 'apse1.api.pms.sentec.io', 'google.com')) {
    try {
        $r = Resolve-DnsName $h -Type A -DnsOnly -ErrorAction Stop | Select-Object -First 1
        $full += "$h -> $($r.IPAddress) [OK]"
    } catch {
        $full += "$h -> FAILED"
    }
}
$full += ''

Write-Host '  [8/12] Ping tests...'
$wa += "*PING*"
$sentecPingAvg = 0
foreach ($h in @('google.com', 'cloudflare.com', 'apse1.pms.sentec.io', 'apse1.api.pms.sentec.io')) {
    Write-Host "    Pinging $h..."
    $p = Test-Connection -ComputerName $h -Count 5 -ErrorAction SilentlyContinue
    if ($p) {
        $avg = [math]::Round(($p | Measure-Object -Property Latency -Average).Average)
        $mn = ($p | Measure-Object -Property Latency -Minimum).Minimum
        $mx = ($p | Measure-Object -Property Latency -Maximum).Maximum
        $full += "$h avg=${avg}ms min=${mn}ms max=${mx}ms loss=0/5"
        $wa += "- ${h}: ${avg}ms [OK]"
        if ($h -eq 'apse1.pms.sentec.io') { $sentecPingAvg = $avg }
    } else {
        $full += "$h FAILED (100% loss)"
        $wa += "- ${h}: FAILED [X]"
    }
}
$full += ''
$wa += ''

Write-Host '  [9/12] AWS Region Latency (cloudping-style)...'
$full += '--- AWS REGION LATENCY (TCP 443 to DynamoDB endpoints) ---'
$wa += "*AWS LATENCY*"
$awsSe1Avg = 0

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
            $awsSe1Avg = $result.Avg
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

# --- VERDICT ---
Write-Host '  [9/12] Generating verdict...'
$wa += "*VERDICT*"
$full += '--- VERDICT ---'
if ($awsSe1Avg -gt 0) {
    if ($awsSe1Avg -lt 50) {
        $full += "AWS ap-southeast-1: ${awsSe1Avg}ms - GOOD path to Singapore"
        $wa += "- AWS SG: ${awsSe1Avg}ms [OK]"
    } elseif ($awsSe1Avg -lt 100) {
        $full += "AWS ap-southeast-1: ${awsSe1Avg}ms - ACCEPTABLE"
        $wa += "- AWS SG: ${awsSe1Avg}ms [~]"
    } elseif ($awsSe1Avg -lt 200) {
        $full += "AWS ap-southeast-1: ${awsSe1Avg}ms - HIGH LATENCY (ISP routing issue likely)"
        $wa += "- AWS SG: ${awsSe1Avg}ms [!] ISP routing issue"
    } else {
        $full += "AWS ap-southeast-1: ${awsSe1Avg}ms - VERY HIGH (ISP blocking/throttling AWS)"
        $wa += "- AWS SG: ${awsSe1Avg}ms [!!] ISP problem"
    }

    if ($sentecPingAvg -gt 0 -and $awsSe1Avg -gt 0) {
        $delta = $sentecPingAvg - $awsSe1Avg
        if ($delta -gt 50) {
            $full += "Sentec overhead: +${delta}ms above raw AWS (app/CDN layer)"
            $wa += "- Sentec overhead: +${delta}ms"
        } elseif ($delta -lt -10) {
            $absDelta = [math]::Abs($delta)
            $full += "Sentec is ${absDelta}ms faster than raw AWS (CDN/edge caching)"
            $wa += "- Sentec faster by ${absDelta}ms (CDN)"
        } else {
            $full += "Sentec latency matches raw AWS (no extra overhead)"
            $wa += "- Sentec = AWS (no overhead)"
        }
    }
} else {
    $full += "Could not reach AWS ap-southeast-1 - possible firewall/ISP block"
    $wa += "- AWS SG: BLOCKED [!!]"
}

if ($ispName) {
    $full += "ISP: $ispName"
    $wa += "- via: *$ispName*"
}
$full += ''
$wa += ''

Write-Host '  [10/12] Traceroute (up to 60s)...'
$full += '--- TRACEROUTE to apse1.pms.sentec.io ---'
$trace = & tracert -d -w 2000 -h 20 apse1.pms.sentec.io 2>$null
if ($trace) { $full += $trace }
$full += ''

Write-Host '  [11/12] Browsers...'
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

Write-Host '  [12/12] Processes and AV...'
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
