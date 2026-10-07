#!/usr/bin/env bash
# Fork-only investigation. No production Dockerfile edits.
set -euo pipefail
mkdir -p transport-evidence
exec > >(tee transport-evidence/driver.log) 2>&1
date -u
git rev-parse HEAD
image=ubuntu:20.04@sha256:8feb4d8ca5354def3d8fce243717141ce31e2c428701f6682bd2fafe15388214
docker pull "$image"
for host in archive.ubuntu.com security.ubuntu.com; do
  suite=focal
  if [[ "$host" == security.ubuntu.com ]]; then suite=focal-security; fi
  getent ahostsv4 "$host" | awk '{print $1}' | sort -u > "transport-evidence/$host-addresses.txt"
  mapfile -t addresses < "transport-evidence/$host-addresses.txt"
  for address in "${addresses[@]:0:2}"; do
    for scheme in http https; do
      port=80
      if [[ "$scheme" == https ]]; then port=443; fi
      name="$host-$address-$scheme"
      code=0
      curl --silent --show-error --fail --connect-timeout 5 --max-time 15 \
        --resolve "$host:$port:$address" --trace-time \
        --trace-ascii "transport-evidence/$name.trace" \
        --output "transport-evidence/$name.body" \
        --write-out 'http=%{http_code} connect=%{time_connect} first_byte=%{time_starttransfer} total=%{time_total}\n' \
        "$scheme://$host/ubuntu/dists/$suite/InRelease" > "transport-evidence/$name.result" 2>&1 || code=$?
      echo "curl_exit=$code" >> "transport-evidence/$name.result"
      cat "transport-evidence/$name.result"
    done
  done
done
for mode in http https-no-ca https-runner-ca; do
  mounts=()
  if [[ "$mode" == https-runner-ca ]]; then
    mounts=(-v /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro)
  fi
  code=0
  timeout --signal=TERM --kill-after=10s 150s docker run --name "ldap-probe-$mode" \
    --rm "${mounts[@]}" -e PROBE_MODE="$mode" "$image" bash -c '
      set -eu
      dpkg-query -W ca-certificates apt || true
      ls -l /etc/ssl/certs/ca-certificates.crt || true
      if [ "$PROBE_MODE" != http ]; then
        sed -i "s|http://|https://|g" /etc/apt/sources.list
      fi
      cat /etc/apt/sources.list
      apt-get -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o Acquire::Retries=0 update
      apt-cache policy krb5-config ca-certificates
      apt-get --simulate install samba krb5-config winbind smbclient
    ' > "transport-evidence/container-$mode.log" 2>&1 || code=$?
  echo "container_exit=$code" >> "transport-evidence/container-$mode.log"
  docker rm -f "ldap-probe-$mode" >/dev/null 2>&1 || true
  tail -12 "transport-evidence/container-$mode.log"
done
