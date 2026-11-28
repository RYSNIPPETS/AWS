#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: invoke.sh --function NAME (--payload JSON | --payload-file FILE)
                 --output-file FILE [--execute] [--yes]

Preview a synchronous Lambda invocation. Because invoking a function can cause side
effects, it requires --execute. The response payload is written to --output-file,
which must not already exist. --yes skips interactive confirmation.
EOF
}

function_name=""
payload=""
payload_file=""
payload_specified=false
payload_file_specified=false
output_file=""
execute=false
ASSUME_YES=false
while (( $# > 0 )); do
  case "$1" in
    --function) [[ $# -ge 2 ]] || die "--function requires a name"; function_name="$2"; shift 2 ;;
    --payload) [[ $# -ge 2 ]] || die "--payload requires JSON"; payload="$2"; payload_specified=true; shift 2 ;;
    --payload-file) [[ $# -ge 2 ]] || die "--payload-file requires a file"; payload_file="$2"; payload_file_specified=true; shift 2 ;;
    --output-file) [[ $# -ge 2 ]] || die "--output-file requires a file"; output_file="$2"; shift 2 ;;
    --execute) execute=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

[[ -n "$function_name" ]] || die "--function is required"
[[ -n "$output_file" ]] || die "--output-file is required"
[[ ! -e "$output_file" && ! -L "$output_file" ]] || die "Output file already exists: $output_file"
if [[ "$payload_specified" == "$payload_file_specified" ]]; then
  die "Specify exactly one of --payload and --payload-file"
fi

require_jq
umask 077
staging="$(mktemp -d "${TMPDIR:-/tmp}/lambda-invoke.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
if [[ "$payload_file_specified" == true ]]; then
  [[ -f "$payload_file" ]] || die "Payload file does not exist: $payload_file"
  cp -- "$payload_file" "$staging/input"
else
  printf '%s' "$payload" >"$staging/input"
fi
jq -es 'length == 1' <"$staging/input" >/dev/null || die "Payload must contain exactly one JSON value"

require_aws
region="$(require_region)"

configuration="$(aws lambda get-function-configuration --region "$region" \
  --function-name="$function_name" --output json)"
jq '{Function: .FunctionName, Runtime, State, LastUpdateStatus, Timeout}' <<<"$configuration"
timeout="$(jq -er '.Timeout | select(type == "number" and . > 0) | . + 30' <<<"$configuration")" \
  || die "Lambda did not return a valid function timeout."
info "Response will be written to: ${output_file}"

if [[ "$execute" != "true" ]]; then
  warn "Preview only. Re-run with --execute to invoke the function."
  exit 0
fi

confirm "Invoke ${function_name} synchronously?"
[[ ! -e "$output_file" && ! -L "$output_file" ]] || die "Output file already exists: $output_file"
set -o noclobber
exec 3>"$output_file"
set +o noclobber

# A transport retry can invoke the function twice if the first response was lost.
if ! metadata="$(AWS_MAX_ATTEMPTS=1 aws lambda invoke \
  --region "$region" \
  --function-name="$function_name" \
  --invocation-type RequestResponse \
  --cli-read-timeout "$timeout" \
  --cli-binary-format raw-in-base64-out \
  --payload "fileb://$staging/input" \
  --output json "$staging/response")"; then
  die "Invocation did not return a response. Check Lambda before retrying. Output reserved at $output_file."
fi
cat -- "$staging/response" >&3
exec 3>&-
jq . <<<"$metadata"
info "Response payload saved to ${output_file}"
if ! jq -e '.StatusCode == 200 and (.FunctionError == null or .FunctionError == "")' \
  <<<"$metadata" >/dev/null; then
  die "Lambda reported an invocation failure. See the saved response payload."
fi
