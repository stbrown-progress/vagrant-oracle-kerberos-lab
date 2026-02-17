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

/opt/oracle/instantclient/sqlplus -V
