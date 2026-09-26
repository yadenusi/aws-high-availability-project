# Project 1: High-Availability Architecture for an E-commerce Application

**AWS SAA-C03 Capstone** · Terraform · us-east-2 · Author: Yusuf Adenusi

An e-commerce company loses revenue because its storefront goes down during peak traffic. This project designs, builds and proves a fault tolerant, self-healing, auto scaling platform on AWS. Every resource is defined in Terraform, and every availability claim is backed by a test that deliberately breaks something.

## At a glance

| Requirement from the brief | Implementation |
|---|---|
| VPC with public and private subnets across multiple AZs | 3 subnet tiers (public, app, data) in 2 AZs, NAT gateway per AZ, S3 gateway endpoint, flow logs |
| EC2 instances in each AZ | Launch template (AL2023, IMDSv2, encrypted gp3, SSM access, no SSH) |
| Elastic Load Balancer with automatic failover | Application Load Balancer, `/health` checks, cross-zone balancing, locked to CloudFront |
| Auto Scaling based on demand | Target tracking on CPU and requests per target, optional peak schedule, rolling instance refresh |
| RDS with Multi-AZ | MySQL 8.0 Multi-AZ, KMS encrypted, TLS enforced, managed master password, 7-day backups |
| RDS read replicas | One read replica in the other AZ, used for catalog reads |
| ElastiCache | Redis 7 replication group, Multi-AZ, automatic failover, TLS and AUTH |
| CloudFront CDN | Static assets from S3 through OAC, 30 second edge cache for the catalog, security headers, maintenance page |
| CloudWatch alarms and SNS | 18 alarms, dashboard, RDS, ElastiCache and ASG event notifications by email |
| CloudTrail monitoring | Multi-region trail, log file validation, KMS encryption |
| Load testing (JMeter) | `scripts/load-test/storefront.jmx` |
| Failure simulation | AWS FIS templates (AZ web tier loss, RDS failover) and a Redis failover script |

Full design, failure analysis and cost: [docs/architecture.md](docs/architecture.md)

## Repository layout

```
project-01-ha-ecommerce/
├── bootstrap/                  # This project's own state bucket and KMS key (run once)
├── versions.tf  providers.tf   # Terraform, provider and backend settings
├── variables.tf  locals.tf     # Inputs and derived values
├── network.tf                  # VPC, subnets, NAT, routes, S3 endpoint, flow logs
├── security_groups.tf          # CloudFront -> ALB -> app -> RDS / Redis chain
├── kms.tf  secrets.tf  iam.tf  # Encryption keys, secrets, roles
├── s3.tf                       # Assets, artifacts, logs, CloudTrail buckets
├── alb.tf  compute.tf          # Load balancer, launch template, Auto Scaling
├── database.tf  cache.tf       # RDS Multi-AZ plus replica, ElastiCache
├── cdn.tf                      # CloudFront
├── monitoring.tf  cloudtrail.tf
├── fis.tf                      # Chaos experiment templates
├── outputs.tf
├── templates/user_data.sh.tftpl
├── app/                        # Flask storefront (deployed to EC2 by Terraform)
├── scripts/                    # verify, availability watcher, JMeter, chaos
├── docs/                       # architecture, testing, troubleshooting
└── evidence/                   # screenshots and test output for the write-up
```

## Prerequisites

- Workstation tools and the AWS account set up per [../docs/workstation-setup.md](../docs/workstation-setup.md)
- An authenticated admin profile: `export AWS_PROFILE=aws-capstone && aws sts get-caller-identity`
- At least 3 Elastic IPs and 16 vCPU of On-Demand quota available in us-east-2

## Deploy

### 1. Create the state bucket (once per project)

```bash
cd project-01-ha-ecommerce/bootstrap
terraform init
terraform apply
```

This creates an encrypted, versioned S3 bucket and a KMS key for this project's state, and writes `../backend.hcl`. The bucket is protected with `prevent_destroy`.

### 2. Configure

```bash
cd ..
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set alert_email at minimum
```

### 3. Initialise, check, estimate, plan

```bash
terraform init -backend-config=backend.hcl
terraform fmt -check -recursive
terraform validate
tflint --init && tflint --config=../.tflint.hcl
checkov -d . --config-file ../.checkov.yaml
infracost breakdown --path .
terraform plan -out tfplan
```

Review the plan: about 150 resources on first apply.

### 4. Apply

```bash
terraform apply tfplan
```

This takes about 20 to 30 minutes. RDS Multi-AZ, the read replica, ElastiCache and CloudFront are the slow parts.

### 5. After apply

1. Confirm **two** SNS subscription emails (one for us-east-2, one for us-east-1).
2. Commit the generated `.terraform.lock.hcl`.
3. Run the checks:
   ```bash
   ./scripts/verify.sh
   terraform output storefront_url
   ```

## Test

Follow [docs/testing.md](docs/testing.md). Summary:

| Test | Command |
|---|---|
| T1 Functional baseline | `./scripts/verify.sh` |
| T2 Load and Auto Scaling | `./scripts/load-test/run-jmeter.sh` |
| T3 AZ loss (web tier) | `./scripts/watch-availability.sh` plus `./scripts/chaos/run-fis.sh az` |
| T4 RDS Multi-AZ failover | `./scripts/watch-availability.sh` plus `./scripts/chaos/run-fis.sh rds` |
| T5 Redis failover | `./scripts/watch-availability.sh` plus `./scripts/chaos/redis-failover.sh` |
| T6 Security checks | commands in the testing guide |

## Tear down

```bash
terraform destroy
```

Takes about 15 to 20 minutes. The state bucket in `bootstrap/` is kept on purpose; it costs a few cents a month. Check Cost Explorer the next day to confirm nothing is left running.

The lab defaults (`force_destroy_buckets`, deletion protection off, skip final snapshot, zero secret recovery window) exist so teardown is clean. Flip them for anything long lived.

## Cost

About **$0.28 per hour** (about $204 per month) while running, mostly NAT gateways, RDS and ElastiCache. A 6 hour build and test session costs about $2 to $3. Breakdown in [docs/architecture.md](docs/architecture.md#7-cost-estimate-us-east-2-on-demand-running-continuously).

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md), which covers the three issues named in the brief and others.

## Results

_To be completed after testing: fill in the results table in [docs/testing.md](docs/testing.md) and summarise the key numbers here (peak instances, p95 latency under load, write downtime during RDS failover, failed requests during AZ loss)._
