#!/bin/bash -e

VERSION='v2.4.0'

if [[ "$OSTYPE" == "linux"* ]]; then
    DOWNLOAD_TYPE="linux-amd64"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    DOWNLOAD_TYPE="darwin-amd64"
fi

echo "[dowload toxiproxy for $DOWNLOAD_TYPE]"
curl --silent -L https://github.com/Shopify/toxiproxy/releases/download/$VERSION/toxiproxy-server-$DOWNLOAD_TYPE -o ./bin/toxiproxy-server

echo "[start toxiproxy]"
chmod +x ./bin/toxiproxy-server
nohup bash -c "./bin/toxiproxy-server 2>&1 | sed -e 's/^/[toxiproxy] /' &"
