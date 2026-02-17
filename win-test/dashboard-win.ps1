# win-test/dashboard-win.ps1 - Windows Status Dashboard (HTTP Listener)
#
# PowerShell HTTP listener that serves a status dashboard on port 80.
# Matches the visual style of the Linux CGI dashboards (same CSS).
# Runs as a Windows service via NSSM (see setup-dashboard.ps1).
#
# Dashboard sections:
#   - Domain Status        - DNS Resolution
#   - Kerberos Tickets     - Java Version
#   - Network Config       - RDP Status

# ── HTML/CSS Template (matches lib/dashboard-common.sh) ──────────

function Get-DashboardCss {
    return @"
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
  background:#f5f7fa;color:#1a1a2e;max-width:960px;margin:0 auto;padding:1rem}
header{background:linear-gradient(135deg,#1a1a2e,#16213e);color:#e0e0e0;
  padding:1.5rem;border-radius:8px;margin-bottom:1.5rem;box-shadow:0 2px 8px rgba(0,0,0,.15)}
header h1{font-size:1.5rem;margin-bottom:.5rem}
header .meta{font-size:.85rem;opacity:.8;line-height:1.6}
header .meta span{display:inline-block;margin-right:1.5rem}
details{background:#fff;border:1px solid #ddd;border-radius:6px;margin-bottom:.75rem;
  box-shadow:0 1px 3px rgba(0,0,0,.04)}
summary{cursor:pointer;padding:.75rem 1rem;font-weight:600;font-size:.95rem;
  background:#e8ecf1;border-radius:6px;user-select:none;list-style:none}
summary::before{content:"&#9656; ";color:#666;font-size:.85rem}
details[open] summary::before{content:"&#9662; "}
details[open] summary{border-bottom:1px solid #ddd;border-radius:6px 6px 0 0}
.section-body{padding:1rem}
.cmd{background:#2d2d2d;color:#66d9ef;padding:.5rem .75rem;border-radius:4px;
  font-family:"Cascadia Code","Fira Code",Consolas,monospace;font-size:.8rem;
  margin-bottom:.5rem;overflow-x:auto;white-space:pre-wrap;word-wrap:break-word}
.cmd::before{content:"PS> ";color:#a6e22e;font-weight:bold}
pre.output{background:#1e1e1e;color:#d4d4d4;padding:.75rem;border-radius:4px;
  overflow-x:auto;font-size:.8rem;max-height:500px;overflow-y:auto;
  white-space:pre-wrap;word-wrap:break-word;line-height:1.4}
.timestamp{text-align:center;color:#888;font-size:.8rem;margin-top:1.5rem;
  padding:1rem 0;border-top:1px solid #e0e0e0}
.nav{display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:1rem}
.nav a{background:#e8ecf1;color:#1a1a2e;text-decoration:none;padding:.4rem .8rem;
  border-radius:4px;font-size:.8rem;border:1px solid #ccc}
.nav a:hover{background:#d0d5dd}
"@
}

function HtmlEscape([string]$text) {
    return [System.Net.WebUtility]::HtmlEncode($text)
}

function Get-Section([string]$title, [string]$cmd, [string]$output, [string]$openAttr = "open") {
    $escapedCmd = HtmlEscape $cmd
    $escapedOutput = HtmlEscape $output
    return @"
<details $openAttr>
<summary>$title</summary>
<div class="section-body">
<div class="cmd">$escapedCmd</div>
<pre class="output">$escapedOutput</pre>
</div>
</details>
"@
}

function RunSection([string]$title, [string]$cmd, [string]$openAttr = "open") {
    try {
        $output = Invoke-Expression $cmd 2>&1 | Out-String
    } catch {
        $output = "ERROR: $_"
    }
    return Get-Section $title $cmd $output $openAttr
}

function Get-DashboardHtml {
    $hostname = $env:COMPUTERNAME
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "Loopback*" } | Select-Object -First 1).IPAddress
    $uptime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $uptimeSpan = (Get-Date) - $uptime
    $uptimeStr = "{0}d {1}h {2}m" -f $uptimeSpan.Days, $uptimeSpan.Hours, $uptimeSpan.Minutes
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"

    $css = Get-DashboardCss

    $sections = @()

    # Domain Status
    $sections += RunSection "Domain Status" "nltest /sc_query:CORP.INTERNAL 2>&1"

    # Kerberos Tickets
    $sections += RunSection "Kerberos Tickets" "klist 2>&1"

    # DNS Resolution
    $dnsOutput = @()
    foreach ($name in @("samba-ad-dc.corp.internal", "oracle.corp.internal")) {
        try {
            $result = Resolve-DnsName -Name $name -Type A -ErrorAction Stop | Out-String
            $dnsOutput += "--- $name ---`n$result"
        } catch {
            $dnsOutput += "--- $name ---`nFailed: $_`n"
        }
    }
    $sections += Get-Section "DNS Resolution" "Resolve-DnsName *.corp.internal" ($dnsOutput -join "`n")

    # Java Version
    $sections += RunSection "Java Version" "java -version 2>&1"

    # Network Configuration
    $sections += RunSection "Network Adapters" "Get-NetIPAddress -AddressFamily IPv4 | Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize | Out-String" ""

    # DNS Client Settings
    $sections += RunSection "DNS Client Settings" "Get-DnsClientServerAddress -AddressFamily IPv4 | Format-Table InterfaceAlias, ServerAddresses -AutoSize | Out-String" ""

    # RDP Status
    $sections += RunSection "Remote Desktop Service" "Get-Service TermService | Format-List Name, Status, StartType | Out-String"

    $sectionsHtml = $sections -join "`n"
    $escapedHostname = HtmlEscape $hostname
    $escapedDomain = HtmlEscape $domain
    $escapedIp = HtmlEscape $ip

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>Windows Client &mdash; Status Dashboard</title>
<style>
$css
</style>
</head>
<body>
<header>
<h1>Windows Client &mdash; Status Dashboard</h1>
<div class="meta">
<span>Hostname: <strong>$escapedHostname</strong></span>
<span>Domain: <strong>$escapedDomain</strong></span>
<span>IP: <strong>$escapedIp</strong></span><br>
<span>Uptime: $uptimeStr</span>
</div>
</header>
<div class="nav">
<a href="http://samba-ad-dc/dashboard">KDC Dashboard</a>
<a href="http://oracle/dashboard">Oracle Dashboard</a>
<a href="http://test-client/dashboard">Test Client Dashboard</a>
<a href="http://win-client/dashboard">Win Client Dashboard</a>
</div>
$sectionsHtml
<div class="timestamp">Generated at $now &mdash; auto-refreshes every 60 seconds</div>
</body>
</html>
"@
}

# ── HTTP Listener ─────────────────────────────────────────────────

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:80/dashboard/")
$listener.Start()
Write-Host "Dashboard listening on http://+:80/dashboard/"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $response = $context.Response

        try {
            $html = Get-DashboardHtml
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
            $response.ContentType = "text/html; charset=utf-8"
            $response.ContentLength64 = $buffer.Length
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        catch {
            $errMsg = "Error generating dashboard: $_"
            $errBuffer = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
            $response.StatusCode = 500
            $response.ContentLength64 = $errBuffer.Length
            $response.OutputStream.Write($errBuffer, 0, $errBuffer.Length)
        }
        finally {
            $response.OutputStream.Close()
        }
    }
}
finally {
    $listener.Stop()
}
