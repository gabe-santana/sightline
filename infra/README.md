# Infrastructure (Terraform)

This provisions the real AWS resources behind [docs/architecture.md](../docs/architecture.md): S3, EventBridge, the two Lambda jobs, RDS, S3 Vectors, and App Runner (`app-service`), publicly accessible directly on its own domain.

## Topology decision: one VPC, not five

The architecture diagram draws 5 logical VPCs (Inbound/App/Jobs/AI/Storage). This Terraform deliberately builds **one VPC with tiered private subnets and Security Groups** instead of 5 peered VPCs — same isolation guarantees (jobs can't reach the data layer they don't need; nothing has a NAT Gateway or general internet egress except the query surface itself), enforced the way AWS's own Well-Architected guidance recommends for segmentation within a single workload, without a peering mesh. See [vpc.tf](vpc.tf) and [security_groups.tf](security_groups.tf) for the actual enforcement.

Every AWS-managed service dependency (S3, Bedrock, Transcribe, Secrets Manager, S3 Vectors) is reached via a VPC endpoint (PrivateLink) rather than a NAT Gateway — there is no NAT Gateway anywhere in this stack, which is both cheaper and tighter (nothing in the compute layer can reach the open internet at all).

## Ingress decision: App Runner public directly, not a gateway or load balancer

`app-service` (AWS App Runner) is **publicly accessible on its own default HTTPS domain** ([apprunner.tf](apprunner.tf)) — no API Gateway, no load balancer, no VPC Ingress Connection in front of it. This went through two earlier iterations:

1. **Amazon API Gateway (HTTP API) + VPC Link + a VPC Ingress Connection**, keeping App Runner private. This worked, but added a gateway, a VPC Link, a dedicated `com.amazonaws.<region>.apprunner.requests` interface endpoint, and their Security Groups just to reach a single backend.
2. **An Application Load Balancer** was considered next (app-service is a full Next.js web app, not just an API, and an ALB is the more natural fit for that). This doesn't work: App Runner's private-ingress PrivateLink endpoint is shared across customers and routes by the `Host` header matching App Runner's own assigned domain. An ALB can route *based on* `Host`, but can't *rewrite* it for the backend request, so it has no way to send the header the endpoint needs — API Gateway's integration type for App Runner private services handles that rewrite internally, which is exactly the workaround an ALB can't replicate.

Given that, the simplest correct option was to drop the private-ingress layer entirely: App Runner already load-balances and autoscales behind its own domain, so making it public directly gets the same functional result (a load-balanced web app endpoint) without maintaining a redundant, and in the ALB case non-functional, layer in front of it. The tradeoff: `app-service` is now the one internet-facing compute resource in the account, rather than a private service behind a single gateway.

## Semantic index decision: S3 Vectors, not OpenSearch

The diagram shows Amazon OpenSearch Service for the vector/semantic index. This Terraform uses **Amazon S3 Vectors** instead ([s3vectors.tf](s3vectors.tf)) — a newer, serverless vector store with no cluster to size, no idle-node cost, and metadata-filtered similarity search (filter by `video_id`, date range, etc. while searching by vector distance), which is exactly what the query agent's retrieval needs. This wasn't a documentation-only decision: it was verified directly against this account before committing to it —

- `aws s3vectors list-vector-buckets` confirmed the service is live in `us-east-1` on this account.
- A real `create-vector-bucket` / `create-index` / `put-vectors` / `query-vectors` round trip, including a metadata filter, returned exactly the filtered nearest-neighbor result RAG retrieval needs.
- `com.amazonaws.us-east-1.s3vectors` exists as an interface VPC endpoint, so the fully-private, no-NAT network design didn't have to change.
- Terraform support (`aws_s3vectors_vector_bucket`, `aws_s3vectors_index`) required bumping the AWS provider from the 5.x series to `~> 6.65` — reviewed the [v5→v6 upgrade guide](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/version-6-upgrade) against every resource type this stack uses before bumping; nothing else in this configuration is affected.

The tradeoff worth knowing: S3 Vectors has no local emulator, so `docker/docker-compose.yml` still runs plain OpenSearch as a local approximation (see [docs/local-development.md](../docs/local-development.md)) — local dev exercises the retrieval *pattern*, not the exact production API.

## Lambda packaging: no Docker, no container images

`transcriber-job` and `embedding-job` deploy as plain zip packages built by a `null_resource` + `local-exec` step in [lambda.tf](lambda.tf) (`pip install --platform manylinux2014_aarch64 --python-version 3.13 --only-binary=:all: ...`), not a Dockerfile. This matters because `psycopg2-binary` has a native extension that must be built for Lambda's actual runtime (Amazon Linux, arm64) — compiling it under QEMU emulation for arm64 on a non-arm64 dev machine turned out to produce a binary with a mismatched Python ABI (`undefined symbol: _PyInterpreterState_Get` at import time). The fix that avoids both Docker and emulation entirely: skip compilation and have pip download an already-built manylinux wheel for the target platform directly from PyPI — confirmed to exist and install cleanly for `psycopg2-binary==2.9.10` before this was relied on here. `terraform apply` runs this build itself (needs `python`/`pip` on the machine running `apply`, not inside any container).

The same trick gets `transcriber-job` a static ffmpeg binary (via the `imageio-ffmpeg` wheel) without Docker or a Lambda Layer: it's used to extract the audio track from containers Amazon Transcribe doesn't accept as `MediaFormat` (MKV, one of the RFP's stated input formats, most notably) into an M4A file it does — see `_normalize_for_transcribe` in `src/transcriber-job/handler.py`. Confirmed end to end before relying on it: the bundled binary supports HTTPS input (`--enable-gnutls`, checked directly against the build), and a synthetic MKV with an Opus audio track (a codec that needs re-encoding, not just remuxing, to reach AAC) extracted cleanly at ~89x realtime. That binary also pushes `transcriber-job`'s zip to ~44MB compressed — close enough to the 50MB limit on an inline-uploaded Lambda deployment package that both jobs now deploy via `aws_s3_object` + `s3_bucket`/`s3_key` instead of passing the zip inline, which only leaves the much higher 250MB *unzipped* limit.

## What's deliberately a placeholder right now

- **`app-service` deploys AWS's public bootstrap image** (`public.ecr.aws/aws-containers/hello-app-runner:latest`, confirmed by inspecting the image directly to listen on port 8000), not the real Next.js app — that real app (`src/app-service`) is fully implemented (Secrets-Manager-backed RDS access, Amazon S3 Vectors retrieval, Amazon Bedrock for embeddings and synthesis) but hasn't been pushed anywhere yet. The bootstrap image exists so App Runner's public endpoint can be created and tested today. An ECR repository is already provisioned and waiting (see the `ecr_repository_url` output) — push the real image there (`docker build -f src/app-service/Dockerfile .` from the repo root, then `docker push`), then set `app_service_image_repository_type = "ECR"`, `app_service_image_identifier = "<ecr_repository_url>:<tag>"`, **and `app_service_port = "8080"`** (src/app-service's real Dockerfile listens on 8080, not the bootstrap image's 8000) in `terraform.tfvars` and re-apply. `runtime_environment_variables` (DB, bucket, S3 Vectors names) are already wired in [apprunner.tf](apprunner.tf) and take effect the moment the real image is deployed.
- **New AWS accounts undergo a fraud-verification hold** (typically resolves within ~2 hours) that blocks some managed-compute/AI services — we hit this directly as `AccessDeniedException: Your account is currently being verified` on Bedrock, and it's the likely cause of `app-service`'s App Runner `CREATE_FAILED` errors during the first applies of this stack. Not a configuration bug; retry once the hold clears.

## Prerequisites

- Terraform >= 1.9, AWS CLI v2, Python + pip (used by the Lambda build step above), all already installed if you followed along in this repo's setup.
- Working AWS credentials (`aws sts get-caller-identity` should succeed — see the AWS CLI auth setup covered earlier).
- **Enable Bedrock model access** for the embedding model `embedding-job` and `app-service` call (`amazon.titan-embed-text-v2:0` by default) and the chat model `app-service`'s query agent uses for synthesis (`anthropic.claude-3-5-haiku-20241022-v1:0` by default), in the Bedrock console → Model access. This is a manual, per-account/per-model opt-in step AWS doesn't expose through Terraform.

## Deploying

```
cd infra
terraform init
terraform plan   # review before applying -- this creates real, billable resources
terraform apply
```

State is local (`terraform.tfstate` in this directory, gitignored) for now. Before more than one person applies this, move to a remote backend:

```
# one-time bootstrap (not yet automated here):
# create an S3 bucket + DynamoDB lock table, then add a backend "s3" block
# to versions.tf pointing at them, and run `terraform init -migrate-state`.
```

## What this actually costs, running continuously

Rough us-east-1 on-demand pricing, dev-sized defaults (single-AZ RDS `db.t4g.micro`):

| Resource | ~Monthly cost |
|---|---|
| RDS `db.t4g.micro`, 20 GB gp3, single-AZ | ~$15 |
| Amazon S3 Vectors | Pay per vector stored + per query — effectively $0 at dev volume, and still usage-scaled at production volume (no idle-node cost, unlike OpenSearch) |
| 4x Interface VPC endpoints (Bedrock, Transcribe, Secrets Manager, S3 Vectors) × 2 AZs | ~$29 |
| App Runner (1 vCPU / 2 GB, while running, publicly accessible — no extra gateway/load-balancer cost) | ~$25–50 depending on usage |
| S3, Lambda, EventBridge | Low single digits at dev volume — these are the genuinely usage-billed pieces the RFP's cost model is about |
| **Total baseline, before any real traffic** | **roughly $70–100/month** |

Dropping OpenSearch's ~$27/month fixed node cost, and not running a gateway or load balancer in front of App Runner, are the two biggest reasons this baseline is lower than an OpenSearch-and-gateway-based design would be. The VPC endpoints are now the main fixed floor — they cost the same whether you process 0 videos or 3,000 hours. If cost matters more than always-on availability for this dev environment, `terraform destroy` between working sessions and `terraform apply` again when you pick it back up is a legitimate way to use this (RDS data won't survive that, since `skip_final_snapshot = true` — fine for a dev environment still being built, not fine once it holds real data; S3 Vectors data would also need `force_destroy = true` set first, see [s3vectors.tf](s3vectors.tf)).

## Outputs

After `apply`, `terraform output` gives you `app_service_url` (App Runner's public HTTPS endpoint) to hit, the S3 bucket name, the RDS endpoint, the S3 Vectors bucket/index names, the Lambda function names (for `aws lambda update-function-code` once real code exists), and the ECR repository URL.
