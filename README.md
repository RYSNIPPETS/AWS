# AWS Administration Scripts

A collection of standalone Bash scripts for AWS administration, resource inventory,
security review, cost visibility, monitoring, and routine infrastructure operations.

The repository currently contains 23 scripts. It is a script library rather than a
single application, so each script has its own purpose, parameters, prerequisites,
and required AWS permissions.

## Script categories

| Location | Scripts | What they cover |
| --- | ---: | --- |
| [`Account/`](Account/) | 1 | Active AWS identity, account alias, profile, and region verification. |
| [`CloudWatch/`](CloudWatch/) | 3 | Log-group discovery, log tailing, and retention-policy management. |
| [`CostManagement/`](CostManagement/) | 2 | Daily and month-to-date AWS Cost Explorer reporting. |
| [`EC2/`](EC2/) | 3 | Instance inventory, unattached EBS volume discovery, and tag-based instance operations. |
| [`IAMSecurity/`](IAMSecurity/) | 2 | IAM access-key age and usage auditing, plus AdministratorAccess policy attachment reporting. |
| [`Lambda/`](Lambda/) | 3 | Function inventory, invocation, and CloudWatch log tailing. |
| [`Networking/`](Networking/) | 3 | VPC, Elastic IP, and load-balancer inventory and cleanup review. |
| [`RDS/`](RDS/) | 3 | Database instance inventory and manual instance or cluster snapshot discovery and creation. |
| [`S3/`](S3/) | 3 | Bucket inventory, public-access review, and directory synchronization. |

### Repository organization

Scripts are grouped by AWS service or administrative purpose. The repository root is
reserved for documentation and repository-wide configuration. Shared Bash helpers are
stored in [`Shared/`](Shared/), validation scripts are stored in [`Tests/`](Tests/),
and the EC2 bootstrap examples that originated in 2018 are in [`Legacy/`](Legacy/).

## Requirements and compatibility

- Bash 3.2 or newer
- A current release of [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).
  The CloudWatch retention scripts require the account-level retention response model.
- [`jq`](https://jqlang.org/download/)
- Configured AWS credentials and the permissions required by the selected script
- An AWS region configured through `AWS_REGION`, `AWS_DEFAULT_REGION`, or the
  active AWS CLI profile for scripts that use regional services

The scripts use the standard AWS CLI credential chain and support named profiles
through `AWS_PROFILE`. Review a script's `--help` output and source before running
it, particularly when using production credentials.

## Repository validation

Run the repository checks from its root:

```bash
make check
```

The validation checks Bash syntax, executable permissions, and every supported
script's help path. Behavioral checks use a local AWS CLI substitute and need no
AWS credentials. ShellCheck also runs when it is installed.

## Service-specific options

- Cost Explorer reports accept `--billing-view-arn` and read all result pages.
- CloudWatch and Lambda tail scripts use Logs Insights for recent events in
  Essentials groups. `--follow` applies to Standard groups. Lambda inventory
  and log tailing require `lambda:GetFunctionConfiguration`.
- S3 reports list general purpose buckets across the account and directory
  buckets in the configured region or `--directory-region`. Use `--general-only`
  with credentials that lack `s3express:ListAllMyDirectoryBuckets`. The public
  access audit's `--object-acls` option checks object version ACLs where applicable.
  It can require one request per object version. Reporting reflects the inspected
  bucket, policy, and ACL signals. Access point policies and organization-level
  controls are outside its coverage.
- S3 sync skips symbolic links. With `--delete`, it checks only the previewed
  keys for deletion after uploads succeed. S3 must report a matching ETag, and
  a newly present local file protects its destination key.
- RDS snapshot creation accepts `--db` or `--cluster`. The age report includes
  both by default and supports `--type instance` and `--type cluster`.

## Getting started

Clone the repository:

```bash
git clone https://github.com/ryroeu/aws.git
cd aws
```

Select a profile and region, then confirm the active AWS identity:

```bash
export AWS_PROFILE=my-sandbox
export AWS_REGION=eu-west-1
./Account/whoami.sh
```

Inspect a script's help before using it:

```bash
./EC2/inventory.sh --help
```

Run a read-only inventory script:

```bash
./EC2/inventory.sh
```

## Important safety notice

Some scripts can change cloud resources, invoke workloads, alter log retention, or
create resources that incur charges. Before using a script in production:

1. Read the complete script and verify its parameters and prerequisites.
2. Confirm the active account, profile, and region.
3. Test it in a non-production environment.
4. Use an IAM principal with only the permissions required for the task.
5. Review the preview before supplying `--execute`.
6. Add `--yes` only in reviewed automation where interactive confirmation is not
   possible.

Do not store access keys, session tokens, passwords, account-specific secrets, or
other credentials in scripts or commit them to the repository.

