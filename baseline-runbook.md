# Baseline Runbook (Operator-Run): CE State in S3

Bob does not run any command in this file. You run them, in order, from the `infra/` folder unless stated. Nothing here contains a credential: use your own AWS profile or `AWS_*` environment variables.

Target facts: region `us-east-1`, state bucket `statebucket-ajs11102026`, state key `demo-cloudblk-provupgrade/terraform.tfstate`, Terraform CLI `>= 1.11.0` (installed here: v1.14.3), provider `hashicorp/aws` `~> 4.67.0`.

## 0. Check identity (read-only)

```bash
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output text
```

Confirm the account is the one you intend to use for the demo.

## 1. Create the state bucket (once, outside Terraform)

```bash
aws s3api create-bucket --bucket statebucket-ajs11102026 --region us-east-1
aws s3api put-bucket-versioning --bucket statebucket-ajs11102026 \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket statebucket-ajs11102026 \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

`us-east-1` takes no `LocationConstraint`. Versioning lets you recover earlier state versions if the migration needs a rollback. Native S3 locking (`use_lockfile = true`) writes a `.tflock` object next to the state, so no DynamoDB table is needed.

## 2. Initialise the S3 backend, plan and apply the baseline

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
rm -f tfplan
```

Review the plan before applying. Expected: 5 resources to add (`aws_s3_bucket.demo`, `aws_s3_bucket_public_access_block.demo`, `aws_s3_bucket_versioning.demo`, `aws_ssm_parameter.demo`, `aws_sns_topic.demo`). If the plan shows anything else, stop and tell Bob.

## 3. Confirm resources and state exist

```bash
terraform state list
aws s3 ls s3://statebucket-ajs11102026/demo-cloudblk-provupgrade/
terraform plan -detailed-exitcode -no-color; echo "exit=$?"
```

Expected: five addresses listed, one state object in S3, and plan exit code `0` (no changes). Keep that exit code as the baseline reference.

## 4. Tag the baseline (after the baseline commit exists)

```bash
git tag -a baseline-s3-aws4 -m "CE baseline: S3 backend, aws provider 4.67.0"
```

Rollback in later sub-tasks restores this tag's backend block.

## Cost (not verified)

I could not retrieve usable pricing pages, so none of these costs is verified yet. From memory only, and to be checked against the AWS pricing pages before you rely on it: an empty S3 bucket, a Standard-tier SSM parameter and an SNS topic have no standing hourly charge; the state files are a few kilobytes. Confirm on the AWS pricing pages for S3, Systems Manager Parameter Store and SNS.

## Teardown

Deferred to sub-task 8. Do not delete the state bucket while any workspace or branch still refers to it.
