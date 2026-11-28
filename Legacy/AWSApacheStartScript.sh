#!/bin/bash
set -Eeuo pipefail

# Supply an S3 prefix containing the static site you intend to publish.
: "${S3_SITE_URI:?Set S3_SITE_URI to a trusted S3 bucket or prefix}"
[[ "$S3_SITE_URI" =~ ^s3://[^/]+(/.*)?$ ]] || {
  printf 'S3_SITE_URI must be an s3:// bucket or prefix.\n' >&2
  exit 1
}
command -v aws >/dev/null
staging="$(mktemp -d "${TMPDIR:-/tmp}/apache-site.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
aws s3 cp "$S3_SITE_URI" "$staging/" --recursive
[[ -f "$staging/index.html" ]] || { printf 'The S3 site has no index.html.\n' >&2; exit 1; }

dnf install -y httpd
cp -R -- "$staging/." /var/www/html/
systemctl enable --now httpd
