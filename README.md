# Serverless API Dynamo Lambda

Terraform-provisioned serverless backend on AWS. Wires together API Gateway, Lambda, DynamoDB, S3, and EventBridge into a data aggregation API deployable across environments via two input variables.

## Architecture

```
EventBridge (rate 2h) ──┐
                         ├──► Lambda (Node.js 18) ──► DynamoDB (userID + timestamp)
API Gateway POST /order ─┘         │
                                    └──► S3 (versioned artifacts bucket)
```

Resource names are parameterized by `project` (default: `data-regen`) and `environment` (default: `dev`), producing names like `data-regen-prod-table` and `data-regen-prod-bucket`.

## Stack

Terraform 1.x · Lambda (Node.js 18) · API Gateway (REST) · DynamoDB (on-demand) · S3 (versioned) · EventBridge · IAM · CloudWatch Logs

## What It Provisions

- **DynamoDB table** — `PAY_PER_REQUEST` billing, composite key (`userID` hash + `timestamp` range)
- **S3 bucket** — versioning enabled for safe artifact overwrites
- **Lambda function** — built in-Terraform via `null_resource` + `npm install --production`; zipped via `archive_file` with `source_code_hash` drift detection
- **EventBridge rule** — invokes Lambda on `rate(2 hours)` schedule
- **API Gateway** — REST API with `POST /order` proxied to Lambda via `AWS_PROXY`
- **IAM role** — inline policy scoped to the project bucket (`s3:PutObject/GetObject/ListBucket`), project table (`dynamodb:Query/Scan`), CloudWatch Logs, and EventBridge

## Repository Layout

```
serverless-api-dynamo-lambda/
├── main.tf               # Full stack definition
├── lambda_handler/
│   ├── index.js          # Lambda handler (exports handler)
│   └── package.json
├── .gitignore
└── README.md
```

## Prerequisites

- Terraform >= 1.3
- Node.js + npm (required for the in-Terraform build step)
- AWS credentials configured with permissions for: Lambda, API Gateway, DynamoDB, S3, IAM, EventBridge, CloudWatch Logs

## Deployment

```bash
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

Before destroying, empty the versioned S3 bucket (versioned objects block deletion):

```bash
aws s3api delete-objects --bucket <bucket> \
  --delete "$(aws s3api list-object-versions --bucket <bucket> \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"

terraform destroy
```
