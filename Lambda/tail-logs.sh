#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: tail-logs.sh --function NAME [--since DURATION] [--follow]

Print recent events from the function's configured CloudWatch log group. The default
duration is 10m. --follow is available for Standard groups. Essentials groups
use a Logs Insights query for recent events.
EOF
}

function_name=""
since="10m"
follow=false
while (( $# > 0 )); do
  case "$1" in
    --function) [[ $# -ge 2 ]] || die "--function requires a name"; function_name="$2"; shift 2 ;;
    --since) [[ $# -ge 2 ]] || die "--since requires a duration"; since="$2"; shift 2 ;;
    --follow) follow=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

[[ -n "$function_name" ]] || die "--function is required"
require_aws
require_jq
region="$(require_region)"

configuration="$(aws lambda get-function-configuration --region "$region" \
  --function-name="$function_name" --output json)"
log_group="$(jq -er '.LoggingConfig.LogGroup // ("/aws/lambda/" + .FunctionName)' <<<"$configuration")"
tail_cloudwatch_log_group "$log_group" "$region" "$since" "$follow"
