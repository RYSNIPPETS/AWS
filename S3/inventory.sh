#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: inventory.sh [--directory-region REGION | --general-only]

List general purpose S3 buckets across the account and directory buckets in the
configured region (default us-east-1). Repeat in other directory bucket regions as
needed. --general-only requires no S3 Express permissions. Output is TSV.

UNKNOWN means the setting could not be read with the active credentials.
EOF
}

directory_region=""
include_directory=true
while (( $# > 0 )); do
  case "$1" in
    --directory-region) [[ -n "${2:-}" ]] || die "--directory-region requires a region"; directory_region="$2"; shift 2 ;;
    --general-only) include_directory=false; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

require_aws
require_jq

region="${directory_region:-$(configured_region)}"
region="${region:-us-east-1}"
buckets="$(s3_buckets "$region" "$include_directory" | jq -r '
  [.Name, (.CreationDate // "-"), (.BucketRegion // "-"), .BucketType] | @tsv')"
printf 'BUCKET\tCREATED\tREGION\tVERSIONING\tALL_PUBLIC_ACCESS_BLOCKS\tTYPE\n'

while IFS=$'\t' read -r bucket created location type; do
  [[ -n "$bucket" ]] || continue

  if [[ "$type" == directory ]]; then
    printf '%s\t%s\t%s\tUNSUPPORTED\ttrue\tdirectory\n' "$bucket" "$created" "$location"
    continue
  fi
  if ! location="$(s3_bucket_region "$bucket" "$location" "$region")"; then
    printf '%s\t%s\tUNKNOWN\tUNKNOWN\tUNKNOWN\tgeneral\n' "$bucket" "$created"
    continue
  fi

  if versioning="$(aws s3api get-bucket-versioning --bucket "$bucket" --region "$location" \
    --query 'Status' --output text 2>/dev/null)"; then
    [[ "$versioning" != "None" ]] || versioning="Disabled"
  else
    versioning="UNKNOWN"
  fi

  if block_json="$(aws s3api get-public-access-block --bucket "$bucket" --region "$location" \
    --output json 2>&1)"; then
    all_blocks="$(jq -r '[.PublicAccessBlockConfiguration.BlockPublicAcls,
      .PublicAccessBlockConfiguration.IgnorePublicAcls,
      .PublicAccessBlockConfiguration.BlockPublicPolicy,
      .PublicAccessBlockConfiguration.RestrictPublicBuckets]
      | if all(type == "boolean") then all else "UNKNOWN" end' <<<"$block_json")"
  elif [[ "$block_json" == *NoSuchPublicAccessBlockConfiguration* ]]; then
    all_blocks="false"
  else
    all_blocks="UNKNOWN"
  fi

  printf '%s\t%s\t%s\t%s\t%s\tgeneral\n' \
    "$bucket" "$created" "$location" "$versioning" "$all_blocks"
done <<<"$buckets"
