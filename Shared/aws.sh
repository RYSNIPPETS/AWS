#!/usr/bin/env bash

# Shared helpers for the AWS CLI scripts. This file is sourced, not executed.

export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

info() {
  printf 'INFO: %s\n' "$*" >&2
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_aws() {
  local version
  require_command aws
  version="$(aws --version 2>&1)"
  case "$version" in
    aws-cli/2.*) ;;
    *) die "AWS CLI v2 is required (found: $version)" ;;
  esac
  aws sts get-caller-identity --output json >/dev/null \
    || die "AWS identity check failed. Verify credentials, network access, and the STS endpoint."
}

require_jq() {
  require_command jq
}

configured_region() {
  local region
  region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  if [[ -z "$region" ]]; then
    region="$(aws configure get region 2>/dev/null || true)"
  fi
  printf '%s\n' "$region"
}

require_region() {
  local region
  region="$(configured_region)"
  [[ -n "$region" ]] || die \
    "No AWS region configured. Set AWS_REGION, AWS_DEFAULT_REGION, or a profile region."
  printf '%s\n' "$region"
}

validate_output() {
  case "$1" in
    table | json | text) ;;
    *) die "Unsupported output format '$1' (expected table, json, or text)" ;;
  esac
}

validate_positive_integer() {
  local LC_ALL=C
  local digits
  [[ "$2" =~ ^0*([1-9][0-9]*)$ ]] || die "$1 must be a positive integer"
  digits="${BASH_REMATCH[1]}"
  if (( ${#digits} > 19 )) ||
    { (( ${#digits} == 19 )) && [[ "$digits" > 9223372036854775807 ]]; }; then
    die "$1 is too large"
  fi
  printf '%s\n' "$digits"
}

# AWS timestamps can include a UTC offset or fractional seconds.
aws_timestamp_jq='
  def aws_timestamp:
    if type == "number" then .
    else
      capture("^(?<time>[0-9T:-]+)(?<fraction>\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$")
      | (((.time + "Z") | fromdateiso8601)
         + (("0" + (.fraction // "")) | tonumber)
         - (if .zone == "Z" then 0
            else (if .zone[0:1] == "+" then 1 else -1 end)
                 * ((.zone[1:3] | tonumber) * 3600 + (.zone[4:6] | tonumber) * 60)
            end))
    end;
'

cost_explorer_periods() {
  local token="" next page
  local -a args
  while :; do
    args=("$@")
    if [[ -n "$token" ]]; then
      args+=(--next-page-token "$token")
    fi
    page="$(aws ce get-cost-and-usage --region us-east-1 --output json "${args[@]}")" || return
    jq -c '.ResultsByTime[]' <<<"$page" || return
    next="$(jq -r '.NextPageToken // empty' <<<"$page")" || return
    [[ -n "$next" ]] || break
    [[ "$next" != "$token" ]] || die "Cost Explorer repeated a continuation token."
    token="$next"
  done
}

cloudwatch_log_group() {
  local name="$1" region="$2"
  aws logs describe-log-groups --region "$region" --log-group-name-prefix="$name" \
    --output json | jq -ce --arg name "$name" '.logGroups[] | select(.logGroupName == $name)'
}

require_logs_retention_metadata() {
  if ! aws logs describe-log-groups --generate-cli-skeleton output --output json |
    jq -e '.logGroups[0] | has("retentionPolicyName")' >/dev/null; then
    die "Update AWS CLI v2 to a release that supports CloudWatch account-level retention metadata."
  fi
}

tail_cloudwatch_log_group() {
  local name="$1" region="$2" since="$3" follow="$4"
  local group class amount unit seconds start end query_id result status
  local -a args
  group="$(cloudwatch_log_group "$name" "$region")" || die "Could not find log group: $name"
  class="$(jq -r '.logGroupClass // "STANDARD"' <<<"$group")"
  case "$class" in
    STANDARD)
      args=(--region "$region" --since "$since" --format short)
      if [[ "$follow" == true ]]; then
        args+=(--follow)
      fi
      aws logs tail "${args[@]}" -- "$name"
      return
      ;;
    DELIVERY) die "Delivery-class logs are read at their configured destination." ;;
    ESSENTIALS | INFREQUENT_ACCESS) ;;
    *) die "Unsupported CloudWatch Logs class: $class" ;;
  esac

  [[ "$follow" == false ]] || die "--follow requires a Standard log group. Omit it to query recent events with Logs Insights."
  [[ "$since" =~ ^([0-9]+)([smhdw])$ ]] || die "--since must be a duration such as 30s, 10m, or 2h."
  unit="${BASH_REMATCH[2]}"
  amount="$(validate_positive_integer "--since" "${BASH_REMATCH[1]}")"
  case "$unit" in
    s) seconds=1 ;;
    m) seconds=60 ;;
    h) seconds=3600 ;;
    d) seconds=86400 ;;
    w) seconds=604800 ;;
  esac
  end="$(date -u +%s)"
  start=0
  if (( amount <= end / seconds )); then
    start=$((end - amount * seconds))
  fi
  query_id="$(aws logs start-query --region "$region" --log-group-name="$name" \
    --start-time "$start" --end-time "$end" --limit 10000 \
    --query-string 'fields @timestamp, @message | sort @timestamp desc' \
    --query queryId --output text)"
  while :; do
    result="$(aws logs get-query-results --region "$region" --query-id "$query_id" --output json)"
    status="$(jq -er '.status' <<<"$result")"
    case "$status" in
      Complete) break ;;
      Scheduled | Running) sleep 1 ;;
      *) die "Logs Insights query $query_id ended with status $status." ;;
    esac
  done
  if jq -e '(.results | length) >= 10000 or (.nextToken != null)' <<<"$result" >/dev/null; then
    warn "Showing the latest 10,000 matching events. Use a shorter --since window for a complete result."
  fi
  jq -r '.results | reverse[] | map({key: .field, value}) | from_entries
    | .["@timestamp"] + " " + .["@message"]' <<<"$result"
}

s3_buckets() {
  local region="$1" include_directory="$2"
  local buckets
  buckets="$(aws s3api list-buckets --region "$region" --page-size 1000 --output json)" || return
  jq -c '(.Buckets // [])[] | . + {BucketType: "general"}' <<<"$buckets" || return
  if [[ "$include_directory" == true ]]; then
    buckets="$(aws s3api list-directory-buckets --region "$region" --page-size 1000 --output json)" || return
    jq -c --arg region "$region" '(.Buckets // [])[]
      | . + {BucketType: "directory", BucketRegion: $region}' <<<"$buckets"
  fi
}

s3_bucket_region() {
  local bucket="$1" listed_region="$2" fallback_region="$3"
  local region
  if [[ "$listed_region" != "-" ]]; then
    printf '%s\n' "$listed_region"
    return
  fi
  region="$(aws s3api head-bucket --bucket "$bucket" --region "$fallback_region" \
    --query 'BucketRegion' --output text)" || return
  [[ -n "$region" && "$region" != None ]] || return 1
  printf '%s\n' "$region"
}

confirm() {
  local prompt="$1"
  local answer
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "Confirmation requires a terminal. Re-run with --yes after reviewing the preview."
  fi
  read -r -p "$prompt [y/N] " answer
  case "$answer" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) die "Cancelled" ;;
  esac
}

utc_date() {
  date -u '+%Y-%m-%d'
}

utc_first_day_of_month() {
  date -u '+%Y-%m-01'
}

utc_days_ago() {
  local days="$1"
  if date -u -d "$days days ago" '+%Y-%m-%d' >/dev/null 2>&1; then
    date -u -d "$days days ago" '+%Y-%m-%d'
  else
    date -u -v-"${days}"d '+%Y-%m-%d'
  fi
}
