<#
.SYNOPSIS
    Monitors a GlobalProtect tunnel during a failover test and writes a
    timestamped CSV you can paste back for analysis.

.DESCRIPTION
    Every interval it probes four independent things and records one CSV row:

      1. TUNNEL      - is the GlobalProtect adapter up, and what IP were we given?
                       The IP says WHICH REGION's pool served us:
                         10.10.200.x = Region A      10.20.200.x = Region B
      2. EGRESS IP   - our public IP as seen from the internet. This is the
                       single most useful signal: it is the firewall's Elastic IP,
                       so it names the region AND proves traffic really leaves
                       through the firewall rather than around the tunnel.
                         <Region A firewall EIP> = Region A
                         <Region B firewall EIP> = Region B
                         anything else = NOT going through the tunnel
      3. INTERNET    - ping 8.8.8.8 (raw IP, no DNS) and an HTTPS fetch (DNS +
                       TLS). Kept separate because DNS usually breaks first.
      4. INTERNAL    - resources reachable ONLY over the tunnel: the AD domain
                       controller and the Spoke1 app. Proves the tunnel carries
                       private traffic, not just internet.

    Everything is wrapped so a failure is recorded, never fatal - the point is
    to capture the outage, not to stop at it.

.EXAMPLE
    .\gp-failover-monitor.ps1
    .\gp-failover-monitor.ps1 -IntervalSeconds 2 -DurationMinutes 30
#>

[CmdletBinding()]
param(
    [int]    $IntervalSeconds = 3,
    [int]    $DurationMinutes = 30,
    [string] $LogPath         = "$env:USERPROFILE\Desktop\gp-failover-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    # Reachable ONLY through the tunnel
    [string] $InternalDcA     = '10.13.0.10',      # Region A domain controller
    [string] $InternalDcB     = '10.23.0.10',      # Region B domain controller
    [string] $InternalApp     = '10.12.0.10',      # Spoke1 Apache

    # Public
    [string] $PortalFqdn      = 'gp.example.com',        # <- your portal FQDN
    [string] $InternetIp      = '8.8.8.8',
    [string] $InternetUrl     = 'https://www.google.com/generate_204',

    # The firewall Elastic IPs, one per region: `terraform output fw_public_eips`.
    # These turn a raw egress IP into "which region is serving me right now",
    # which is the single clearest signal of a failover.
    [string] $EipRegionA      = 'REPLACE_ME',
    [string] $EipRegionB      = 'REPLACE_ME'
)

$script:EipRegionA = $EipRegionA
$script:EipRegionB = $EipRegionB

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'   # stops Invoke-WebRequest being slow

# --- helpers ---------------------------------------------------------------

function Test-Ping {
    param([string]$Target, [int]$TimeoutMs = 1500)
    try {
        $r = (New-Object System.Net.NetworkInformation.Ping).Send($Target, $TimeoutMs)
        if ($r.Status -eq 'Success') { return [pscustomobject]@{ Ok = $true;  Ms = [int]$r.RoundtripTime } }
    } catch { }
    return [pscustomobject]@{ Ok = $false; Ms = -1 }
}

function Test-TcpPort {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 1500)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        if ($c.ConnectAsync($Target, $Port).Wait($TimeoutMs) -and $c.Connected) { return $true }
    } catch { } finally { $c.Dispose() }
    return $false
}

function Get-EgressIp {
    # Two providers so one being down does not look like an outage.
    foreach ($u in @('https://api.ipify.org', 'https://ifconfig.me/ip')) {
        try {
            $ip = (Invoke-WebRequest -Uri $u -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop).Content.Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        } catch { }
    }
    return 'FAIL'
}

function Get-TunnelInfo {
    # The GlobalProtect virtual adapter; name varies by version, so match loosely.
    $nic = Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -match 'PANGP|GlobalProtect' -and $_.Status -eq 'Up'
    } | Select-Object -First 1

    if (-not $nic) { return [pscustomobject]@{ Up = $false; Ip = 'none'; Region = 'DISCONNECTED' } }

    $ip = (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).IPAddress | Select-Object -First 1
    if (-not $ip) { return [pscustomobject]@{ Up = $true; Ip = 'none'; Region = 'NO-IP' } }

    $region = switch -Regex ($ip) {
        '^10\.10\.200\.' { 'A' }
        '^10\.20\.200\.' { 'B' }
        default          { 'UNKNOWN' }
    }
    return [pscustomobject]@{ Up = $true; Ip = $ip; Region = $region }
}

function Resolve-EgressRegion {
    param([string]$Ip)
    switch ($Ip) {
        $script:EipRegionA { 'A' }
        $script:EipRegionB { 'B' }
        'FAIL'          { 'FAIL' }
        default         { 'OUTSIDE-TUNNEL' }
    }
}

# --- run -------------------------------------------------------------------

$deadline = (Get-Date).AddMinutes($DurationMinutes)
$rows     = @()
$seq      = 0

Write-Host "Logging to: $LogPath"
Write-Host "Interval ${IntervalSeconds}s, duration ${DurationMinutes}min. Ctrl+C stops early (log is kept)." -ForegroundColor Cyan
Write-Host ""

try {
    while ((Get-Date) -lt $deadline) {
        $seq++
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'

        $tun      = Get-TunnelInfo
        $egress   = Get-EgressIp
        $egRegion = Resolve-EgressRegion $egress

        $pIcmp    = Test-Ping $InternetIp
        $pDcA     = Test-Ping $InternalDcA
        $pDcB     = Test-Ping $InternalDcB

        $httpOk   = $false
        # -ErrorAction Stop is REQUIRED: with $ErrorActionPreference = 'SilentlyContinue'
        # a failed request is non-terminating, never reaches catch, and $httpOk would
        # be set to $true on an outage — the exact opposite of what we are measuring.
        try { $null = Invoke-WebRequest -Uri $InternetUrl -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop; $httpOk = $true } catch { }

        $appOk    = Test-TcpPort $InternalApp 80
        $ldapOk   = Test-TcpPort $InternalDcA 389
        $portalOk = Test-TcpPort $PortalFqdn 443

        $row = [pscustomobject]@{
            Seq             = $seq
            Timestamp       = $ts
            TunnelUp        = $tun.Up
            TunnelIp        = $tun.Ip
            PoolRegion      = $tun.Region
            EgressIp        = $egress
            EgressRegion    = $egRegion
            PingInternet    = $pIcmp.Ok
            PingInternetMs  = $pIcmp.Ms
            HttpsInternet   = $httpOk
            PingDcA         = $pDcA.Ok
            PingDcAMs       = $pDcA.Ms
            PingDcB         = $pDcB.Ok
            LdapDcA         = $ldapOk
            AppSpoke1       = $appOk
            PortalTcp443    = $portalOk
        }
        $rows += $row
        $rows | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8

        # Console line: green = all good, red = something is down.
        $healthy = $tun.Up -and $pIcmp.Ok -and $httpOk -and $pDcA.Ok
        $colour  = if ($healthy) { 'Green' } else { 'Red' }
        Write-Host ("{0}  tun={1,-12} egress={2,-15} (region {3})  inet={4}/{5}  dcA={6}  app={7}" -f `
            $ts, $tun.Ip, $egress, $egRegion, $pIcmp.Ok, $httpOk, $pDcA.Ok, $appOk) -ForegroundColor $colour

        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    $rows | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Saved $($rows.Count) samples to $LogPath" -ForegroundColor Cyan

    if ($rows.Count -gt 0) {
        Write-Host ""
        Write-Host "=== SUMMARY ===" -ForegroundColor Yellow
        $down = $rows | Where-Object { -not $_.PingInternet }
        Write-Host ("internet ping loss : {0}/{1} samples" -f $down.Count, $rows.Count)
        $dcDown = $rows | Where-Object { -not $_.PingDcA }
        Write-Host ("internal DC loss   : {0}/{1} samples" -f $dcDown.Count, $rows.Count)
        Write-Host "egress IPs seen    :"
        $rows | Group-Object EgressIp | ForEach-Object {
            Write-Host ("   {0,-16} x{1}" -f $_.Name, $_.Count)
        }
        Write-Host "tunnel IPs seen    :"
        $rows | Group-Object TunnelIp | ForEach-Object {
            Write-Host ("   {0,-16} x{1}" -f $_.Name, $_.Count)
        }
        # The moments that matter: any change of egress IP = a path switch.
        $changes = for ($i = 1; $i -lt $rows.Count; $i++) {
            if ($rows[$i].EgressIp -ne $rows[$i-1].EgressIp) {
                "{0}  {1} -> {2}" -f $rows[$i].Timestamp, $rows[$i-1].EgressIp, $rows[$i].EgressIp
            }
        }
        if ($changes) {
            Write-Host "path switches      :" -ForegroundColor Yellow
            $changes | ForEach-Object { Write-Host "   $_" }
        } else {
            Write-Host "path switches      : none"
        }
    }
}
