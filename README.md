# Serverless Data Aggregation API — DynamoDB + Lambda + API Gateway

This project provisions a fully serverless **data aggregation / regeneration** backend on AWS using Terraform. It wires together a **DynamoDB** table (keyed on `userID` + `timestamp`), a versioned **S3 bucket** for derived artifacts, an **AWS Lambda** function (Node.js 18.x) that can be invoked either on a schedule (every two hours via EventBridge) or on demand over HTTP, and a **REST API Gateway** with a `/order` POST endpoint proxied straight to the Lambda. The Lambda source is built in place — `npm install --production` runs through a Terraform `null_resource` + `local-exec` provisioner, and the resulting directory is zipped via the `archive_file` data source and shipped to Lambda with automatic `source_code_hash` drift detection.

## Highlights

- **End-to-end IaC for a serverless API** — API Gateway, Lambda, IAM, EventBridge, DynamoDB, and S3 all defined in a single `main.tf`.
- **In-Terraform Lambda build pipeline** — `null_resource` triggers on `package.json` / `index.js` checksum changes, runs `npm install --production`, and zips the result via `data.archive_file`; no external CI step needed.
- **DynamoDB on-demand billing** (`PAY_PER_REQUEST`) — no capacity planning, cost scales with use. Composite key (`userID` hash + `timestamp` range) supports per-user time-series queries.
- **S3 versioning enabled** on the aggregated-data bucket — safe overwrite semantics for regenerated artifacts.
- **Dual invocation paths** — scheduled (`rate(2 hours)` EventBridge rule) and HTTP (API Gateway `POST /order` with `AWS_PROXY` integration).
- **Least-privilege IAM** — the Lambda's inline policy grants `s3:PutObject`/`GetObject`/`ListBucket` scoped to the project bucket, `dynamodb:Query`/`Scan` scoped to the project table, CloudWatch Logs, and EventBridge rule management.

## Architecture

```
                 +------------------------+
                 |  EventBridge           |
                 |  rate(2 hours)         |
                 +-----------+------------+
                             |
  client --> API Gateway --> Lambda (Node 18) --> DynamoDB (userID, timestamp)
            POST /order      regen_function
                                   |
                                   v
                         S3 bucket (versioned)
                         <project>-<env>-bucket
```

Resource names are parameterized by two variables (`project`, defaulting to `data-regen`; `environment`, defaulting to `dev`), so the same config can be applied to dev / staging / prod with per-env names (e.g. `data-regen-prod-table`, `data-regen-prod-bucket`).

## Tech stack

- **Terraform** 1.x (AWS provider)
- **AWS services:** Lambda, API Gateway (REST, v1), DynamoDB (on-demand), S3 (versioned), EventBridge (CloudWatch Events rule), IAM, CloudWatch Logs
- **Other:** Node.js 18.x (Lambda runtime), npm (for building `lambda_handler/`), `archive_file` data source, `null_resource` + `local-exec` provisioner

## Repository layout

```
TABLE_LAMBDA/
├── README.md
├── .gitignore
├── main.tf          # Entire stack: S3, DynamoDB, IAM, Lambda, EventBridge, API GW
└── main-old.txt     # Earlier hardcoded version, kept as reference (not used by Terraform)
```

The Lambda source directory (`lambda_handler/` with `index.js` + `package.json`) is expected to sit alongside `main.tf` — `main.tf` references it for the build + zip steps. It is not present in this snapshot; add your handler source before running `terraform apply`.

## How it works

1. `terraform apply` creates the S3 bucket (with versioning on) and the DynamoDB table (`userID` hash, `timestamp` range, `PAY_PER_REQUEST`).
2. The `null_resource.lambda_dependencies` provisioner executes `npm install --production` inside `lambda_handler/` whenever `package.json` or `index.js` checksum changes.
3. `data.archive_file.lambda_zip` zips that directory into `lambda_function.zip`.
4. An IAM role trusting `lambda.amazonaws.com` is created and attached to an inline policy scoped to the project's S3 bucket, DynamoDB table, CloudWatch Logs, and EventBridge.
5. The Lambda function is created from the zip, with environment variables `BUCKET_NAME`, `DYNAMODB_TABLE`, and `ENV` injected.
6. An EventBridge rule (`rate(2 hours)`) is created, the Lambda is given `lambda:InvokeFunction` permission for EventBridge, and the rule target points at the function.
7. An API Gateway REST API with a `POST /order` resource is created using `AWS_PROXY` integration to the Lambda, deployed to a `prod` stage.
8. Outputs print the API invoke URL, bucket name, Lambda name, and EventBridge rule name.

## Prerequisites

- Terraform >= 1.3
- Node.js + npm installed locally (required for the build provisioner)
- AWS CLI configured (`aws configure`) with permissions for: `s3:*` (on the project bucket), `dynamodb:*`, `lambda:*`, `iam:CreateRole`/`CreatePolicy`/`AttachRolePolicy`, `events:*`, `apigateway:*`, `logs:*`.
- A populated `lambda_handler/` folder with `index.js` (exporting `handler`) and a `package.json`.

## Deployment

```bash
# Make sure lambda_handler/ exists with index.js + package.json
terraform init
terraform plan
terraform apply
```

Invoke the HTTP endpoint:

```bash
curl -X POST "$(terraform output -raw api_endpoint)/order" \
     -H "Content-Type: application/json" \
     -d '{"userID":"u1","payload":"..."}'
```

## Teardown

```bash
terraform destroy
```

Empty the versioned S3 bucket before destroy (versioned objects block bucket deletion):

```bash
aws s3api delete-objects --bucket <bucket> \
  --delete "$(aws s3api list-object-versions --bucket <bucket> \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
```

## Notes

- Demonstrates: fully serverless IaC, Terraform-driven Lambda build pipeline, parameterized multi-env naming, dual (scheduled + HTTP) invocation, and scoped IAM policies.
- `main-old.txt` is the earlier un-parameterized version of the same stack (hardcoded resource names like `aggregated-data-poc`, `AggregatedData`, `lambda_execution_role`) — kept in the repo as a diff reference showing the refactor to variables + an in-Terraform build pipeline. It is not read by Terraform.
- The API Gateway stage is created without an explicit redeploy trigger — for a real pipeline, add a `triggers` block on `aws_api_gateway_deployment` keyed on the integration/method hash to avoid drift.
