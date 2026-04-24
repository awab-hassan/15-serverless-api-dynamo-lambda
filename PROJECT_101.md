# PROJECT_101: TABLE_LAMBDA

## What is this?
A Lambda function triggered by **DynamoDB Streams** — when a table row changes, the function runs.

## Why it matters
Streams + Lambda = event-driven architecture without a message bus. The Lambda can forward changes to another system, denormalize into another table, or fire webhooks.

## What you did
- Enabled a Stream on the source table (NEW_AND_OLD_IMAGES)
- Wrote the Lambda handler to process batched records
- Set up a DLQ (dead-letter queue) for failed batches

## Interview one-liner
"I built a Dynamo-Streams → Lambda pipeline — change-data-capture without a dedicated bus, with DLQ safety."

## Key concepts
- **Stream view types** (KEYS_ONLY, NEW_IMAGE, OLD_IMAGE, NEW_AND_OLD_IMAGES)
- **Lambda batch size** + **batching window**
- **DLQ** via SQS for failure isolation
