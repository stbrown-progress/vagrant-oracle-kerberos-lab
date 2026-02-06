#!/bin/bash
# Shared retry-download helper. Source this file, then call:
#   fetch_with_retry <url> <dest> [attempts] [wait_seconds]

fetch_with_retry() {
    local url=$1
    local dest=$2
    local attempts=${3:-10}
    local wait_s=${4:-3}

    for i in $(seq 1 $attempts); do
        if wget -q "$url" -O "$dest"; then
            return 0
        fi
        echo "Download failed ($i/$attempts): $url"
        sleep "$wait_s"
    done

    echo "Failed to download after $attempts attempts: $url"
    return 1
}
