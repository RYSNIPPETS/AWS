#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: log-groups-without-retention.sh [--output table|json|text]

List CloudWatch Logs groups in the configured region without a group or account
retention policy. Fixed-retention Delivery groups are excluded. Default output: table.
EOF
}

output=table
while (( $# > 0 )); do
  case "$1" in
    --output) [[ $# -ge 2 ]] || die "--output requires a value"; output="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

validate_output "$output"
require_aws
require_jq
region="$(require_region)"
require_logs_retention_metadata

aws logs describe-log-groups \
  --region "$region" \
  --query 'logGroups[?retentionInDays==null && retentionPolicyName==null && logGroupClass!=`DELIVERY`].{LogGroup:logGroupName,StoredBytes:storedBytes,CreatedMillis:creationTime,Class:logGroupClass}' \
  --output "$output"
