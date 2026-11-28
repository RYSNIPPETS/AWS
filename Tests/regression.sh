#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
staging="$(mktemp -d "${TMPDIR:-/tmp}/aws-regression.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
export AWS_TEST_CALLS="$staging/calls"
export AWS_TEST_SOURCE="$staging/source"
export AWS_REGION=eu-west-1
export PATH="$staging:$PATH"

cat >"$staging/date" <<'EOF'
#!/bin/bash
case "$*" in
  '-u +%Y-%m-01') printf '2026-11-01\n' ;;
  '-u +%Y-%m-%d') printf '2026-11-28\n' ;;
  *) exec /bin/date "$@" ;;
esac
EOF

cat >"$staging/aws" <<'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" >>"$AWS_TEST_CALLS"
if [[ "$1" == --version ]]; then
  printf 'aws-cli/2.fixture\n'
  exit 0
fi
case "$1 $2" in
  'sts get-caller-identity')
    case "$*" in
      *'--query Account'*) printf '111122223333\n' ;;
      *'--query Arn'*) printf 'arn:aws:iam::111122223333:role/test\n' ;;
      *) printf '%s\n' '{"Account":"111122223333","Arn":"arn:aws:iam::111122223333:role/test","UserId":"test"}' ;;
    esac ;;
  'iam list-account-aliases') printf 'AccessDenied\n' >&2; exit 254 ;;
  'iam list-users') printf '%s\n' '{"Users":[{"UserName":"None"}]}' ;;
  'iam list-access-keys')
    [[ "$*" == *'--user-name=None'* ]]
    printf '%s\n' '{"AccessKeyMetadata":[{"AccessKeyId":"fixture","Status":"Active","CreateDate":"2020-01-01T00:00:00.123+00:00"}]}' ;;
  'iam get-access-key-last-used') printf '%s\n' '{"AccessKeyLastUsed":{}}' ;;
  'iam list-entities-for-policy')
    [[ "$*" == *'--policy-usage-filter PermissionsPolicy'* ]]
    printf '%s\n' '{"PolicyRoles":[{"RoleName":"attached-role"}]}' ;;
  'ec2 describe-instances')
    cat <<'JSON'
{"Reservations":[{"Instances":[
 {"InstanceId":"i-exact","State":{"Name":"running"},"Tags":[{"Key":"Name","Value":"example?"}]},
 {"InstanceId":"i-larger","State":{"Name":"running"},"Tags":[{"Key":"Name","Value":"example1"}]}
]}]}
JSON
    ;;
  'ec2 stop-instances')
    [[ "$*" == *'--instance-ids i-exact --query '* ]] ;;
  'ce get-cost-and-usage')
    [[ "$*" == *'--billing-view-arn arn:fixture'* ]]
    start=2026-11-01
    finish=2026-11-02
    service=first-service
    token=next
    if [[ "$*" == *'--next-page-token next'* ]]; then
      service=second-service
      token=""
      if [[ "$*" == *'--granularity DAILY'* ]]; then
        start=2026-11-02
        finish=2026-11-03
      fi
    fi
    jq -nc --arg service "$service" --arg token "$token" --arg start "$start" --arg finish "$finish" '
      {Amount: "0.123456789123456789", Unit: "USD"} as $cost
      | {NextPageToken: $token, ResultsByTime: [
          {TimePeriod: {Start: $start, End: $finish}, Estimated: true,
           Total: {UnblendedCost: $cost}, Groups: [{Keys: [$service], Metrics: {UnblendedCost: $cost}}]}
        ]}'
    ;;
  'lambda list-functions') printf '%s\n' '["sample"]' ;;
  'lambda get-function-configuration')
    if [[ "$AWS_TEST_CASE" == inventory ]]; then
      printf '%s\n' '{"Function":"sample","State":"Failed","Architectures":"arm64"}'
    else
      printf '%s\n' '{"FunctionName":"sample","Timeout":120,"LoggingConfig":{"LogGroup":"custom-group"}}'
    fi ;;
  'lambda invoke')
    [[ "${AWS_MAX_ATTEMPTS:-}" == 1 && "$*" == *'--cli-read-timeout 150 '* ]]
    printf '%s\n' '{"errorMessage":"fixture error"}' >"${!#}"
    printf '%s\n' '{"StatusCode":200,"FunctionError":"Unhandled"}' ;;
  'logs describe-log-groups')
    case "$*" in
      *'--generate-cli-skeleton'*)
        if [[ "$AWS_TEST_CASE" == old-cli ]]; then
          printf '%s\n' '{"logGroups":[{}]}'
        else
          printf '%s\n' '{"logGroups":[{"retentionPolicyName":""}]}'
        fi ;;
      *'--log-group-name-prefix=custom-group'*)
        printf '%s\n' '{"logGroups":[{"logGroupName":"custom-group","logGroupClass":"ESSENTIALS"}]}' ;;
      *)
        if [[ "$AWS_TEST_CASE" == account-retention ]]; then
          printf '%s\n' '{"logGroups":[{"logGroupName":"sample","retentionInDays":90,"retentionPolicyName":"baseline"}]}'
        else
          printf '%s\n' '{"logGroups":[{"logGroupName":"sample","logGroupClass":"STANDARD"}]}'
        fi ;;
    esac ;;
  'logs put-retention-policy') [[ "$*" == *'--retention-in-days 30'* ]] ;;
  'logs start-query') [[ "$*" == *'--log-group-name=custom-group'* ]]; printf 'test-query-id\n' ;;
  'logs get-query-results')
    printf '%s\n' '{"status":"Complete","results":[[{"field":"@timestamp","value":"2026-11-28 00:00:00"},{"field":"@message","value":"test log"}]]}' ;;
  's3api list-buckets')
    [[ "$*" == *'--page-size 1000'* ]]
    if [[ "$AWS_TEST_CASE" == bad-json ]]; then
      printf 'invalid response\n'
    else
      printf '%s\n' '{"Buckets":[{"Name":"fixture-bucket","BucketRegion":"us-west-2"}]}'
    fi ;;
  's3api list-directory-buckets') printf '%s\n' '{"Buckets":[{"Name":"fixture--euw1-az1--x-s3"}]}' ;;
  's3api get-bucket-versioning') [[ "$*" == *'--region us-west-2'* ]]; printf 'None\n' ;;
  's3control get-public-access-block') printf 'NoSuchPublicAccessBlockConfiguration\n' >&2; exit 254 ;;
  's3api get-public-access-block')
    if [[ "$AWS_TEST_CASE" == blocked-read ]]; then
      printf 'AccessDenied\n' >&2
    else
      printf 'NoSuchPublicAccessBlockConfiguration\n' >&2
    fi
    exit 254 ;;
  's3api get-bucket-policy-status') printf 'NoSuchBucketPolicy\n' >&2; exit 254 ;;
  's3api get-bucket-ownership-controls')
    if [[ "$AWS_TEST_CASE" == blocked-read ]]; then
      printf '%s\n' '{"OwnershipControls":{"Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]}}'
    else
      printf '%s\n' '{"OwnershipControls":{"Rules":[{"ObjectOwnership":"ObjectWriter"}]}}'
    fi ;;
  's3api get-bucket-acl') printf '%s\n' '{"Grants":[]}' ;;
  's3api list-object-versions') printf '%s\n' '{"Versions":[{"Key":"example","VersionId":"old-version"}]}' ;;
  's3api get-object-acl')
    [[ "$*" == *old-version* ]]
    printf '%s\n' '{"Grants":[{"Grantee":{"URI":"http://acs.amazonaws.com/groups/global/AllUsers"}}]}' ;;
  's3 sync')
    [[ "$*" == *'--no-follow-symlinks'* && "$*" != *'--delete'* ]]
    if [[ "$*" != *'--dryrun'* ]]; then
      printf 'new local file\n' >"$AWS_TEST_SOURCE/new-local"
    fi ;;
  's3api list-objects-v2')
    [[ "$*" == *'--prefix folder/'* ]]
    printf '%s\n' '{"Contents":[{"Key":"folder/keep","ETag":"etag-keep"},{"Key":"folder/stale\n","ETag":"etag-old"},{"Key":"folder/new-local","ETag":"etag-current"},{"Key":"folder/local-link","ETag":"etag-link"}]}' ;;
  's3api delete-object')
    [[ "$*" == *'"Key":"folder/stale\n"'* && "$*" == *'"IfMatch":"etag-old"'* ]] ;;
  'rds describe-db-instances') printf '%s\n' '{"Status":"stopped"}' ;;
  'rds describe-db-clusters') printf '%s\n' '{"Status":"available"}' ;;
  'rds create-db-cluster-snapshot') [[ "$*" == *'--db-cluster-snapshot-identifier=snapshot-id'* ]] ;;
  'rds describe-db-snapshots')
    printf '%s\n' '{"DBSnapshots":[{"DBSnapshotIdentifier":"no-date"},{"DBSnapshotIdentifier":"old-instance","SnapshotCreateTime":"2020-01-01T00:00:00.350Z"}]}' ;;
  'rds describe-db-cluster-snapshots')
    printf '%s\n' '{"DBClusterSnapshots":[{"DBClusterSnapshotIdentifier":"old-cluster","SnapshotCreateTime":"2020-01-01T03:00:00+03:00"}]}' ;;
  *) printf 'Unexpected AWS CLI fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$staging/aws" "$staging/date"
mkdir "$AWS_TEST_SOURCE"
printf 'keep\n' >"$AWS_TEST_SOURCE/keep"
ln -s "$staging/absent-target" "$AWS_TEST_SOURCE/local-link"

run() {
  local scenario="$1" script="$2"
  shift 2
  : >"$AWS_TEST_CALLS"
  status=0
  AWS_TEST_CASE="$scenario" bash "$ROOT_DIR/$script" "$@" >"$staging/out" 2>"$staging/err" || status=$?
}

fail() {
  printf 'Regression failed: %s (status %s)\n' "$1" "$status" >&2
  cat "$staging/out" "$staging/err" "$AWS_TEST_CALLS" >&2
  exit 1
}

run alias Account/whoami.sh
[[ "$status" == 0 ]] && jq -e '.account_alias_status == "unreadable"' "$staging/out" >/dev/null ||
  fail 'unreadable account alias'
run keys IAMSecurity/audit-access-keys.sh
[[ "$status" == 0 ]] && grep -q 'None.*fixture.*STALE' "$staging/out" ||
  fail 'IAM username and fractional timestamp'
run overflow IAMSecurity/audit-access-keys.sh --days 18446744073709551617
[[ "$status" != 0 && ! -s "$AWS_TEST_CALLS" ]] || fail 'oversized day count'
run policy IAMSecurity/list-admin-attachments.sh
[[ "$status" == 0 ]] && grep -q 'attached-role' "$staging/out" || fail 'permissions policy filter'

run ec2 EC2/stop-by-tag.sh --tag 'Name=example?' --execute --yes
[[ "$status" == 0 ]] && grep -q 'stop-instances.*i-exact' "$AWS_TEST_CALLS" || fail 'literal EC2 tag'
run cost CostManagement/daily-costs.sh --billing-view-arn arn:fixture
[[ "$status" == 0 ]] && grep -q '2026-11-02' "$staging/out" || fail 'daily cost continuation'
run cost CostManagement/month-to-date.sh --billing-view-arn arn:fixture
[[ "$status" == 0 ]] && grep -q 'second-service.*0\.123456789123456789' "$staging/out" ||
  fail 'monthly cost continuation and amount'

run function-error Lambda/invoke.sh --function sample --payload false --output-file "$staging/response" --execute --yes
[[ "$status" != 0 ]] && grep -q 'fixture error' "$staging/response" || fail 'Lambda error metadata'
run function-payload Lambda/invoke.sh --function sample --payload 'true false' --output-file "$staging/unused"
[[ "$status" != 0 && ! -s "$AWS_TEST_CALLS" ]] || fail 'multiple JSON values'
run function-output Lambda/invoke.sh --function sample --payload null --output-file "$staging/missing/response" --execute --yes
[[ "$status" != 0 ]] && ! grep -q 'lambda invoke' "$AWS_TEST_CALLS" || fail 'unwritable Lambda output'
run inventory Lambda/inventory.sh --output json
[[ "$status" == 0 ]] && jq -e '.[0].State == "Failed"' "$staging/out" >/dev/null || fail 'Lambda inventory state'
run custom-log Lambda/tail-logs.sh --function sample
[[ "$status" == 0 ]] && grep -q 'test log' "$staging/out" || fail 'Lambda custom Essentials log group'
run account-retention CloudWatch/set-log-retention.sh --log-group sample --days 30 --execute --yes
[[ "$status" != 0 ]] && ! grep -q 'put-retention-policy' "$AWS_TEST_CALLS" || fail 'account retention precedence'
run old-cli CloudWatch/set-log-retention.sh --log-group sample --days 30 --execute --yes
[[ "$status" != 0 ]] && ! grep -q 'put-retention-policy' "$AWS_TEST_CALLS" || fail 'old retention model'
run valid-retention CloudWatch/set-log-retention.sh --log-group sample --days 30 --execute --yes
[[ "$status" == 0 ]] && grep -q 'put-retention-policy' "$AWS_TEST_CALLS" || fail 'group retention operation'
run bad-retention CloudWatch/set-log-retention.sh --log-group sample --days '30 60'
[[ "$status" != 0 && ! -s "$AWS_TEST_CALLS" ]] || fail 'multiple retention day counts'

run directories S3/inventory.sh
[[ "$status" == 0 ]] && grep -q 'fixture--euw1-az1--x-s3.*directory' "$staging/out" ||
  fail 'S3 directory inventory'
run bad-json S3/inventory.sh
[[ "$status" != 0 ]] || fail 'S3 parse failure'
run blocked-read S3/audit-public-access.sh --general-only
[[ "$status" == 0 ]] && grep -q 'fixture-bucket.*INCOMPLETE_DATA' "$staging/out" ||
  fail 'S3 unreadable blocking'
run public-object S3/audit-public-access.sh --object-acls
[[ "$status" == 0 ]] && grep -q 'fixture-bucket.*REVIEW_PUBLIC_ACCESS' "$staging/out" ||
  fail 'S3 public object version'
run sync S3/sync-directory.sh --source "$AWS_TEST_SOURCE" --destination s3://fixture-bucket/folder --delete --execute --yes
[[ "$status" == 0 ]] && grep -q 'delete-object.*etag-old' "$AWS_TEST_CALLS" || fail 'S3 conditional deletion'
[[ "$(grep -c 'list-objects-v2' "$AWS_TEST_CALLS")" == 1 ]] || fail 'S3 fixed deletion plan'

run unavailable-db RDS/create-snapshot.sh --db sample
[[ "$status" != 0 ]] && grep -q 'ineligible' "$staging/err" || fail 'RDS snapshot source state'
run cluster RDS/create-snapshot.sh --cluster sample --snapshot snapshot-id --execute --yes
[[ "$status" == 0 ]] && grep -q 'create-db-cluster-snapshot' "$AWS_TEST_CALLS" || fail 'RDS cluster snapshot'
run snapshots RDS/find-old-manual-snapshots.sh
[[ "$status" == 0 ]] && grep -q 'old-instance' "$staging/out" && grep -q 'old-cluster' "$staging/out" &&
  ! grep -q 'no-date' "$staging/out" || fail 'RDS snapshot age and type'

printf 'All behavioral regression checks passed.\n'
