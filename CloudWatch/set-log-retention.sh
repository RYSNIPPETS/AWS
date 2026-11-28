#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: set-log-retention.sh --log-group NAME --days N [--execute] [--yes]

Preview a retention change for one CloudWatch Logs group. N must be a retention value
accepted by CloudWatch Logs. Nothing changes without --execute; --yes skips the
interactive confirmation.
EOF
}

log_group=""
days=""
execute=false
ASSUME_YES=false
while (( $# > 0 )); do
  case "$1" in
    --log-group) [[ $# -ge 2 ]] || die "--log-group requires a name"; log_group="$2"; shift 2 ;;
    --days) [[ $# -ge 2 ]] || die "--days requires a value"; days="$2"; shift 2 ;;
    --execute) execute=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

[[ -n "$log_group" ]] || die "--log-group is required"
case "$days" in
  1 | 3 | 5 | 7 | 14 | 30 | 60 | 90 | 120 | 150 | 180 | 365 | 400 | 545 | 731 | 1096 | \
    1827 | 2192 | 2557 | 2922 | 3288 | 3653) ;;
  *) die "--days must be one of: 1 3 5 7 14 30 60 90 120 150 180 365 400 545 731 1096 1827 2192 2557 2922 3288 3653" ;;
esac

require_aws
region="$(require_region)"

require_jq
require_logs_retention_metadata
current="$(cloudwatch_log_group "$log_group" "$region")" || die "Could not find log group: $log_group"
printf 'LOG_GROUP\tRETENTION_DAYS\tACCOUNT_POLICY\tCLASS\tSTORED_BYTES\n'
jq -r '[.logGroupName, (.retentionInDays // "-"), (.retentionPolicyName // "-"),
         (.logGroupClass // "STANDARD"), .storedBytes] | @tsv' <<<"$current"
info "Proposed retention: ${days} days"

if jq -e '.logGroupClass == "DELIVERY" or .retentionPolicyName != null' <<<"$current" >/dev/null; then
  die "This group uses fixed Delivery retention or an account retention policy. Group-level changes cannot set its effective retention."
fi

if [[ "$execute" != "true" ]]; then
  warn "Preview only. Re-run with --execute to set retention."
  exit 0
fi

confirm "Set retention on ${log_group} to ${days} days?"
current="$(cloudwatch_log_group "$log_group" "$region")" || die "Could not recheck log group: $log_group"
if jq -e '.logGroupClass == "DELIVERY" or .retentionPolicyName != null' <<<"$current" >/dev/null; then
  die "The group is now governed by fixed Delivery retention or an account policy."
fi
aws logs put-retention-policy --region "$region" \
  --log-group-name="$log_group" --retention-in-days "$days"
info "CloudWatch Logs accepted the group-level retention setting for ${log_group}."
