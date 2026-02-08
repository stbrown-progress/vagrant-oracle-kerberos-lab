#!/bin/bash
# lib/dashboard-common.sh - Shared HTML generation helpers for VM dashboards
# Source this file from each VM's CGI script.
# Do NOT use set -e — diagnostics that fail should not kill the page.

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

dashboard_begin() {
    local title="$1"
    local vm_hostname
    vm_hostname=$(hostname -f 2>/dev/null || hostname)
    local vm_ip
    vm_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local vm_uptime
    vm_uptime=$(uptime -p 2>/dev/null || uptime)

    printf "Content-Type: text/html\r\n"
    printf "\r\n"

    cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>${title}</title>
<style>
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
summary::before{content:"▸ ";color:#666;font-size:.85rem}
details[open] summary::before{content:"▾ "}
details[open] summary{border-bottom:1px solid #ddd;border-radius:6px 6px 0 0}
.section-body{padding:1rem}
.cmd{background:#2d2d2d;color:#66d9ef;padding:.5rem .75rem;border-radius:4px;
  font-family:"Cascadia Code","Fira Code",Consolas,monospace;font-size:.8rem;
  margin-bottom:.5rem;overflow-x:auto;white-space:pre-wrap;word-wrap:break-word}
.cmd::before{content:"$ ";color:#a6e22e;font-weight:bold}
pre.output{background:#1e1e1e;color:#d4d4d4;padding:.75rem;border-radius:4px;
  overflow-x:auto;font-size:.8rem;max-height:500px;overflow-y:auto;
  white-space:pre-wrap;word-wrap:break-word;line-height:1.4}
.timestamp{text-align:center;color:#888;font-size:.8rem;margin-top:1.5rem;
  padding:1rem 0;border-top:1px solid #e0e0e0}
.nav{display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:1rem}
.nav a{background:#e8ecf1;color:#1a1a2e;text-decoration:none;padding:.4rem .8rem;
  border-radius:4px;font-size:.8rem;border:1px solid #ccc}
.nav a:hover{background:#d0d5dd}
</style>
</head>
<body>
<header>
<h1>${title}</h1>
<div class="meta">
<span>Hostname: <strong>${vm_hostname}</strong></span>
<span>IP: <strong>${vm_ip}</strong></span><br>
<span>Uptime: ${vm_uptime}</span>
</div>
</header>
HTMLHEAD
}

# Render navigation links to other dashboards
dashboard_nav() {
    cat <<'HTMLNAV'
<div class="nav">
<a href="http://samba-ad-dc/dashboard">KDC Dashboard</a>
<a href="http://oracle/dashboard">Oracle Dashboard</a>
<a href="http://test-client/dashboard">Test Client Dashboard</a>
</div>
HTMLNAV
}

# Render a diagnostic section with pre-captured output
# Args: title, command_string, output [, open_attr]
dashboard_section() {
    local title="$1"
    local cmd="$2"
    local output="$3"
    local open_attr="${4:-open}"

    local escaped_output
    escaped_output=$(html_escape "$output")
    local escaped_cmd
    escaped_cmd=$(html_escape "$cmd")

    cat <<HTMLSECTION
<details ${open_attr}>
<summary>${title}</summary>
<div class="section-body">
<div class="cmd">${escaped_cmd}</div>
<pre class="output">${escaped_output}</pre>
</div>
</details>
HTMLSECTION
}

# Convenience: run a command, capture output, render section
# Args: title, command_string [, open_attr]
dashboard_run_section() {
    local title="$1"
    local cmd="$2"
    local open_attr="${3:-open}"
    local output
    output=$(eval "$cmd" 2>&1) || true
    dashboard_section "$title" "$cmd" "$output" "$open_attr"
}

dashboard_end() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S %Z')
    cat <<HTMLEND
<div class="timestamp">Generated at ${now} &mdash; auto-refreshes every 60 seconds</div>
</body>
</html>
HTMLEND
}
