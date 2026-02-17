#!/bin/bash
# lib/setup-dashboard.sh - Deploy Nginx + CGI status dashboard
#
# Shared by all Linux VMs (kdc, oracle, test). Expects two files
# already uploaded by the Vagrant file provisioner:
#   /tmp/dashboard-common.sh   - shared HTML helpers
#   /tmp/dashboard-vm.sh       - VM-specific dashboard CGI script
#
# Usage: source /tmp/setup-dashboard.sh

# ── Nginx site configuration ─────────────────────────────────────
# Serves static files at / (with directory listing) and the CGI
# dashboard at /dashboard via fcgiwrap.
cat <<'EOF' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html index.htm;
    server_name _;

    location / {
        try_files $uri $uri/ =404;
        autoindex on;
        autoindex_localtime on;
    }

    location = /dashboard {
        gzip off;
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/local/lib/dashboard-vm.sh;
        fastcgi_pass unix:/var/run/fcgiwrap.socket;
    }
}
EOF

# ── Install dashboard scripts ────────────────────────────────────
cp /tmp/dashboard-common.sh /usr/local/lib/dashboard-common.sh
cp /tmp/dashboard-vm.sh     /usr/local/lib/dashboard-vm.sh
# Strip Windows carriage returns that break bash shebangs
sed -i 's/\r$//' /usr/local/lib/dashboard-common.sh /usr/local/lib/dashboard-vm.sh
chmod +x /usr/local/lib/dashboard-vm.sh

# ── Run fcgiwrap as root ─────────────────────────────────────────
# The dashboard calls systemctl, samba-tool, docker, etc. which
# require root privileges.
mkdir -p /etc/systemd/system/fcgiwrap.service.d
cat <<'EOF' > /etc/systemd/system/fcgiwrap.service.d/override.conf
[Service]
User=root
Group=root
EOF
systemctl daemon-reload
systemctl stop fcgiwrap.service fcgiwrap.socket 2>/dev/null || true
systemctl enable fcgiwrap.socket
systemctl start fcgiwrap.socket

# ── Start Nginx ──────────────────────────────────────────────────
systemctl enable nginx
systemctl restart nginx
