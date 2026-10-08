#!/bin/bash
# Replace krdp's one-day certificate with a long-lived self-signed one.
#
#   ./make-cert.sh NAME [NAME|IP ...]
#   e.g. ./make-cert.sh myhost myhost.lan 192.168.1.10
#
# krdp 6.3.5 generates its certificate with `openssl req -days 1`, so it expires
# after a day and Windows warns on every connection. A CA-signed certificate
# makes mstsc warn that it can't check revocation instead. A self-signed
# certificate, trusted as a root on Windows, gets neither warning, the same as
# Windows' own RDP certificates.
#
# Writes to ~/.local/share/krdpserver/selfsigned/, points krdp at it, turns off
# krdp's own certificate generation, and restarts krdp. Prints the path of a
# .cer file to import on Windows. Set KRDP_CERT_DIR to write elsewhere, or
# NO_CONFIGURE=1 to skip changing krdp's settings.
set -euo pipefail

[ $# -ge 1 ] || { sed -n '2,5p' "$0"; exit 1; }

dir="${KRDP_CERT_DIR:-$HOME/.local/share/krdpserver/selfsigned}"
days="${DAYS:-1825}"

san=""
for n in "$@"; do
    if [[ "$n" =~ ^[0-9.]+$ || "$n" == *:* ]]; then san+="IP:$n,"; else san+="DNS:$n,"; fi
done
san="${san%,}"

mkdir -p "$dir"
chmod 700 "$dir"
cat > "$dir/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $1
[v3]
keyUsage = critical, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $san
subjectKeyIdentifier = hash
EOF

openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days "$days" \
    -keyout "$dir/krdp.key" -out "$dir/krdp.crt" -config "$dir/cert.cnf" 2>/dev/null
chmod 600 "$dir/krdp.key"
openssl x509 -in "$dir/krdp.crt" -outform der -out "$dir/krdp.cer"
openssl x509 -in "$dir/krdp.crt" -noout -subject -enddate -ext subjectAltName

if [ "${NO_CONFIGURE:-0}" != 1 ]; then
    kwriteconfig6 --file krdpserverrc --group General --key Certificate "$dir/krdp.crt"
    kwriteconfig6 --file krdpserverrc --group General --key CertificateKey "$dir/krdp.key"
    kwriteconfig6 --file krdpserverrc --group General --key AutogenerateCertificates false
    systemctl --user restart app-org.kde.krdpserver.service
    echo "krdp now uses $dir/krdp.crt"
fi

echo
echo "On Windows, in an admin prompt:  certutil -addstore -f Root krdp.cer"
echo "Copy this file there: $dir/krdp.cer"
