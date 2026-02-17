#!/bin/bash
# oracle/setup-docker.sh - Install Docker and run the Oracle Free container
#
# Uses --net=host so the Oracle listener binds directly to the VM's IP
# (required for Kerberos service tickets to match the hostname).
#
# Volumes mounted into the container:
#   /opt/artifacts   -> /tmp/keytabs    (krb5.conf + keytabs)
#   /opt/scripts     -> /opt/scripts    (SQL scripts, sqlnet.ora, setup helper)

# ── Install Docker (idempotent) ──────────────────────────────────
if ! command -v docker &> /dev/null; then
    echo "==> Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker vagrant
    systemctl enable docker
    systemctl start docker
fi

# ── Run Oracle Free container (idempotent) ───────────────────────
if [ ! "$(docker ps -q -f name=oracle)" ]; then
    # Remove any stopped container with the same name
    if [ "$(docker ps -aq -f name=oracle)" ]; then
        docker rm oracle
    fi

    echo "==> Starting Oracle Free container..."
    docker run -d --name oracle \
        --restart unless-stopped \
        --net=host \
        -e ORACLE_PWD=Str0ngPassw0rd! \
        -v /opt/artifacts:/tmp/keytabs \
        -v /opt/scripts:/opt/scripts \
        -v /opt/scripts/sqlnet.ora:/opt/scripts/sqlnet.ora \
        -v /opt/scripts/setup-sqlnet.sh:/docker-entrypoint-initdb.d/setup-sqlnet.sh \
        container-registry.oracle.com/database/free:latest
else
    echo "==> Oracle container already running."
fi
