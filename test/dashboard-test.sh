#!/bin/bash
# Test Client Status Dashboard - CGI Script
source /usr/local/lib/dashboard-common.sh

dashboard_begin "Test Client — Status Dashboard"
dashboard_nav

dashboard_run_section "DNS: Resolve KDC" \
    "dig +short samba-ad-dc.corp.internal"

dashboard_run_section "DNS: Resolve Oracle" \
    "dig +short oracle.corp.internal"

dashboard_run_section "KDC Connectivity (port 88)" \
    "nc -zv samba-ad-dc.corp.internal 88 2>&1"

dashboard_run_section "Oracle Connectivity (port 1521)" \
    "nc -zv oracle.corp.internal 1521 2>&1"

dashboard_run_section "Kerberos Configuration" \
    "cat /etc/krb5.conf"

dashboard_run_section "Kerberos Ticket Cache" \
    "sudo -u vagrant klist 2>&1 || echo 'No active tickets'"

dashboard_run_section "Java Version" \
    "java -version 2>&1"

# Check if Oracle Instant Client is installed
ic_output=""
if [ -d /opt/oracle/instantclient ]; then
    ic_output=$(/opt/oracle/instantclient/sqlplus -V 2>&1 && echo "" && ls -la /opt/oracle/instantclient/ 2>&1) || true
else
    ic_output="Oracle Instant Client not yet installed. Run: ./install-oracle.sh"
fi
dashboard_section "Oracle Instant Client" \
    "sqlplus -V && ls -la /opt/oracle/instantclient/" \
    "$ic_output"

dashboard_run_section "SQL*Net Client Configuration" \
    "cat /opt/oracle/instantclient/network/admin/sqlnet.ora 2>/dev/null || echo 'Not yet configured'"

dashboard_run_section "NTP Status" \
    "chronyc tracking"

dashboard_run_section "Available Helper Scripts" \
    "ls -la /home/vagrant/*.sh /home/vagrant/*.isql /home/vagrant/*.keytab 2>/dev/null || echo 'No helper files found'"

dashboard_run_section "DNS Configuration" \
    "cat /etc/resolv.conf"

dashboard_end
