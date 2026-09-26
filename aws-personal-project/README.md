# AWS Solutions Architect Capstone Projects

Twelve hands-on AWS architecture projects built for the AWS Solutions Architect Associate (SAA-C03) capstone. Every project is written from scratch in **Terraform**, deployed to a real AWS account, tested against failure scenarios, documented with evidence, and then torn down.

**Author:** Yusuf Adenusi

## How the repo is organized

Each `project-XX-*` folder is fully self-contained. It has its own Terraform state bucket (created by its own `bootstrap/` stack), its own variables, application code, test scripts, documentation and evidence. No infrastructure code is shared between projects. Only repo tooling (linting, security scanning and CI) lives at the root.

| # | Project | Focus | Status |
|---|---|---|---|
| 01 | [High-Availability E-commerce](project-01-ha-ecommerce/) | Multi-AZ VPC, ALB, Auto Scaling, RDS Multi-AZ and read replica, ElastiCache, CloudFront, FIS chaos testing | In progress |
| 02 | Cost Optimization for Media Streaming | Spot and mixed instances, S3 lifecycle, CloudFront, Lambda, cost monitoring | Planned |
| 03 | Disaster Recovery for Healthcare | Cross-region backup and replication, Route 53 failover | Planned |
| 04 | Serverless Social Media Analytics | Lambda, API Gateway, DynamoDB, SNS, Kinesis, Glue | Planned |
| 05 | AWS Account Setup and IAM Mastery | IAM, MFA enforcement, permissions boundaries, budgets | Planned |
| 06 | CDN for a Donation Website | S3, CloudFront, Lambda, API Gateway | Planned |
| 07 | E-commerce Monitoring (ShopHub) | CloudWatch dashboards, alarms, agent, Synthetics | Planned |
| 08 | CloudTrail Security Logging (DailyBuzz) | CloudTrail, S3 lifecycle, CloudWatch alarms, SNS | Planned |
| 09 | Backup Strategy (FinSecure) | AWS Backup, Vault Lock, restore testing | Planned |
| 10 | Database Migration (LocalMart) | AWS DMS, RDS MySQL | Planned |
| 11 | Mobile App Backend (FitLife) | Cognito, API Gateway, Lambda, DynamoDB | Planned |
| 12 | HelpDesk Chatbot | Amazon Lex V2, Lambda, Slack | Planned |

## Standards used in every project

- **Region:** `us-east-2` (a second region only where the design requires it)
- **Terraform:** `>= 1.11`, AWS provider `~> 6.0`, provider lock file committed
- **State:** a separate S3 bucket per project with KMS encryption, versioning and S3 native locking
- **Security:** encryption at rest and in transit, private subnets for compute and data, least privilege IAM, no secrets in git
- **Tagging:** Project, Environment, Owner, ManagedBy, Capstone
- **Quality gates:** `terraform fmt`, `validate`, `tflint`, `checkov` and `gitleaks` through pre-commit and GitHub Actions

## Getting started

1. Read the program standards: [docs/capstone-strategy.md](docs/capstone-strategy.md)
2. Set up your workstation: [docs/workstation-setup.md](docs/workstation-setup.md)
3. Complete the one-time AWS account preparation in the same guide
4. Open a project folder and follow its README

## Lifecycle of each project

Design, plan, build, static checks, cost estimate, deploy, test and capture evidence, destroy, write-up, merge.
