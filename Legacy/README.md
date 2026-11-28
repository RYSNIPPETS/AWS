# Legacy examples

These EC2 user-data examples originated in 2018 and use Amazon Linux 2023 package
and service commands. They remain demo bootstrap scripts.

- `AWSApacheCreateScript.sh` starts Apache with a sample page.
- `AWSApacheStartScript.sh` publishes a static site from a trusted `S3_SITE_URI`.
  The instance role needs access to list and read that source.
- `RDS.sh` prepares Apache and PHP with the MySQL client driver for an RDS application.
  Provision and configure the database separately.

