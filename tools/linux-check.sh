#!/bin/bash
# Builds the Swift bridge in a Linux container and smoke-tests the web server.
#   tools/linux-check.sh            (needs Docker; the source is piped in, so no folder sharing is required)
cd "$(dirname "$0")/.."
tar cf - Package.swift Sources public config.json | docker run --rm -i swift:6.1 bash -c '
  mkdir -p /build && cd /build && tar xf -
  apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq libasound2-dev curl >/dev/null 2>&1 || echo "apt install failed"
  swift build 2>&1 | grep -E "error|warning: unused|Build complete|rror:" | head -40
  [ -x .build/debug/rc505 ] || { echo "NO BINARY"; exit 1; }
  .build/debug/rc505 --port 5999 & sleep 2
  curl -s -o /dev/null -w "overlay http %{http_code}\n" localhost:5999/overlay
  curl -s localhost:5999/api/state | cut -c1-200; echo
  curl -s -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" --max-time 2 localhost:5999/ | head -4 | tr -d "\r"
  echo; echo "expected accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="'
