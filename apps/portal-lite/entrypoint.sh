#!/bin/sh
set -eu

export HOSTNAME=0.0.0.0
export PORT=8080
mkdir -p /tmp/next-cache

./portal-api &
api_pid=$!
node server.js &
next_pid=$!

terminate() {
  kill -TERM "${api_pid}" "${next_pid}" 2>/dev/null || true
  wait "${api_pid}" "${next_pid}" 2>/dev/null || true
}
trap terminate INT TERM EXIT

while kill -0 "${api_pid}" 2>/dev/null && kill -0 "${next_pid}" 2>/dev/null; do
  sleep 1
done

exit 1
