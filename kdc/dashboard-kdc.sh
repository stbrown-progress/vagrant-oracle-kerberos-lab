#!/bin/bash
# KDC (Samba AD DC) Status Dashboard - CGI Script
source /usr/local/lib/dashboard-common.sh

dashboard_begin "Samba AD DC — Status Dashboard"
dashboard_nav

dashboard_run_section "Samba AD DC Service" \
    "systemctl status samba-ad-dc --no-pager -l"

dashboard_run_section "Domain Information" \
    "samba-tool domain info 127.0.0.1"

dashboard_run_section "DNS: KDC A Record" \
    "samba-tool dns query localhost corp.internal samba-ad-dc A -U Administrator --password='Str0ngPassw0rd!'"

dashboard_run_section "DNS: Oracle A Record" \
    "samba-tool dns query localhost corp.internal oracle A -U Administrator --password='Str0ngPassw0rd!'"

dashboard_run_section "Domain Users" \
    "samba-tool user list"

dashboard_run_section "SPNs for oracleuser" \
    "samba-tool spn list oracleuser"

dashboard_run_section "Keytab: oracle.keytab" \
    "klist -k /var/www/html/artifacts/oracle.keytab"

dashboard_run_section "Keytab: oracleuser.keytab" \
    "klist -k /var/www/html/artifacts/oracleuser.keytab"

dashboard_run_section "Keytab: dnsupdater.keytab" \
    "klist -k /var/www/html/artifacts/dnsupdater.keytab"

dashboard_run_section "NTP Status" \
    "chronyc tracking"

dashboard_run_section "Nginx Status" \
    "systemctl status nginx --no-pager -l"

dashboard_run_section "Artifacts Directory" \
    "ls -la /var/www/html/artifacts/"

dashboard_run_section "Samba Logs (last 50 lines)" \
    "tail -50 /var/log/samba/log.samba 2>/dev/null || echo 'No log.samba found'" \
    ""

dashboard_end
