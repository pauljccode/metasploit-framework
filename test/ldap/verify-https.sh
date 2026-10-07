#!/usr/bin/env bash
# Fork-only verification; the proposed change is confined to the Dockerfile.
set -euo pipefail
cd test/ldap
docker compose exec -T ldap bash -s <<'CONTAINER'
set -euo pipefail
if grep -Eq '^deb(-src)?[[:space:]]+http://' /etc/apt/sources.list; then
  echo 'Unexpected HTTP package source' >&2
  exit 1
fi
dpkg-query -W -f='${Status} ${Version}\n' ca-certificates
test -s /etc/ssl/certs/ca-certificates.crt
probe_dir=$(mktemp -d)
trap 'rm -rf "$probe_dir"' EXIT
chmod 755 "$probe_dir"
mkdir -p "$probe_dir/lists/partial"
printf '%s\n' 'deb https://archive.ubuntu.com/ubuntu focal main' > "$probe_dir/sources.list"
# A valid certificate bundle for an unrelated root must not authenticate Ubuntu.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=UntrustedProbe \
  -keyout "$probe_dir/key.pem" -out "$probe_dir/wrong-ca.pem" 2>/dev/null
code=0
apt-get -o "Dir::Etc::sourcelist=$probe_dir/sources.list" \
  -o Dir::Etc::sourceparts=- -o "Dir::State::lists=$probe_dir/lists" \
  -o "Acquire::https::CAInfo=$probe_dir/wrong-ca.pem" \
  -o Acquire::https::Timeout=10 -o Acquire::Retries=0 \
  update > "$probe_dir/rejection.log" 2>&1 || code=$?
cat "$probe_dir/rejection.log"
test "$code" -ne 0
grep -q 'Certificate verification failed' "$probe_dir/rejection.log"
echo 'LDAP_HTTPS_UNTRUSTED_CA_REJECTED'
# The same clean package-list location succeeds with the installed trust store.
apt-get -o "Dir::Etc::sourcelist=$probe_dir/sources.list" \
  -o Dir::Etc::sourceparts=- -o "Dir::State::lists=$probe_dir/lists" \
  -o Acquire::https::Timeout=10 -o Acquire::Retries=0 update
find "$probe_dir/lists" -name '*InRelease' | grep -q .
echo 'LDAP_HTTPS_SYSTEM_CA_ACCEPTED'
CONTAINER
