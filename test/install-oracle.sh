#!/bin/bash
set -e

# Minimal Oracle Instant Client install (no ldconfig)

sudo apt-get update
sudo apt-get install -y wget unzip libaio1

wget https://download.oracle.com/otn_software/linux/instantclient/1929000/instantclient-basic-linux.x64-19.29.0.0.0dbru.zip
wget https://download.oracle.com/otn_software/linux/instantclient/1929000/instantclient-sqlplus-linux.x64-19.29.0.0.0dbru.zip

sudo mkdir -p /opt/oracle
sudo unzip -o instantclient-basic-linux.x64-19.29.0.0.0dbru.zip -d /opt/oracle
sudo unzip -o instantclient-sqlplus-linux.x64-19.29.0.0.0dbru.zip -d /opt/oracle

sudo rm -rf /opt/oracle/instantclient
sudo ln -s /opt/oracle/instantclient_19_29 /opt/oracle/instantclient

# Restore SQL*Net config for Kerberos authentication.
# Provisioning deploys sqlnet.ora into /opt/oracle/instantclient/network/admin,
# but the rm+symlink above destroys it. Re-deploy from the provisioned copy.
sudo mkdir -p /opt/oracle/instantclient/network/admin
if [ -f /tmp/lib/sqlnet-client.ora ]; then
    sudo cp /tmp/lib/sqlnet-client.ora /opt/oracle/instantclient/network/admin/sqlnet.ora
    echo "sqlnet.ora deployed to /opt/oracle/instantclient/network/admin/"
else
    echo "WARNING: /tmp/lib/sqlnet-client.ora not found -- run 'lab provision test' to restore it"
fi

/opt/oracle/instantclient/sqlplus -V
