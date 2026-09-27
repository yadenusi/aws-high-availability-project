# Setup Journal: What We Did, What Each Thing Is, and Why

**Author:** Yusuf Adenusi\
**Program:** AWS Solutions Architect (SAA-C03) Capstone, 14 projects in Terraform\
**Repo:** github.com/yadenusi/aws-high-availability-project

This is the running record of every step taken to set up the capstone environment, in the order it happened. For each step it explains what was done, what the thing is, and why the project needs it. Keep it next to the runbook. New steps get added to the end as we go.

---

## Part 1: The big picture in one paragraph

Your laptop runs Windows. The tools used to build cloud infrastructure professionally (Terraform, the AWS CLI, bash scripts) are built for Linux first, so we installed a Linux system inside Windows (WSL2 with Ubuntu). Your code lives in a Git repository on GitHub, so it is backed up, versioned and visible to reviewers. From Ubuntu you run Terraform, which reads the project's `.tf` files and builds the whole architecture in your AWS account. The AWS CLI gives Terraform and the test scripts permission to act in your account. Checking tools (checkov, tflint, pre-commit) catch mistakes before anything is deployed, and testing tools (curl, jq, JMeter, the Session Manager plugin) prove that the deployed system survives failures and traffic spikes.

---

## Part 2: What we have done so far, step by step

### Step 1: Tried `unzip` in PowerShell (it failed)

- **What happened:** you typed `unzip aws-personal-project` in PowerShell and got "not recognized".
- **Why it failed:** PowerShell is the Windows command line. `unzip` is a Linux command, so PowerShell does not have it. The file name also needed its full name, `aws-personal-project-p01.zip`.
- **Lesson:** everything in this program runs in the **Ubuntu** window, never in PowerShell.

### Step 2: Installed Linux on Windows (WSL2 with Ubuntu)

- **What it is:** WSL2 (Windows Subsystem for Linux) runs a real Linux system inside Windows. Ubuntu is the Linux version installed in it. Yours is Ubuntu 26.04 (code name "resolute").
- **Why we need it:** all project scripts are bash scripts, and Terraform, the AWS CLI and the testing tools behave the same way here as on the Linux servers used in industry. It also avoids Windows problems such as file paths with spaces and Windows line endings breaking scripts.
- **Where your Windows files are from Ubuntu:** `/mnt/c/Users/Yusuf Adenusi/...`. Your Ubuntu home folder is `/home/yusuf_adenusi` (also written `~`).

### Step 3: Put the code in a GitHub repository

- **What Git is:** a version control system. It records every change to your files as a "commit", so you can see history, undo mistakes and work on branches.
- **What GitHub is:** a website that stores Git repositories online. It is your backup, your portfolio and where the automatic checks (GitHub Actions) run.
- **Your repo:** `github.com/yadenusi/aws-high-availability-project`, cloned to `~/aws-high-availability-project` in Ubuntu.
- **Why we need it:** the brief requires the code to be checked into a repository, and reviewers or employers will read it there.

### Step 4: Found and removed a duplicate folder

- **What happened:** unzipping created a second copy of everything inside `aws-high-availability-project/aws-personal-project/`.
- **What we did:** checked the copy was identical (`diff -rq`, which printed `IDENTICAL`), then deleted it (`git rm` and `rm -rf`).
- **Why it mattered:** two copies of the same Terraform project would confuse Terraform and Git and double the size of the repo.

### Step 5: Added a `.gitattributes` file

- **What it is:** a settings file that tells Git how to treat file types.
- **What ours says:** always store files with Linux line endings (LF), especially `.sh`, `.tf` and `.tftpl` files.
- **Why we need it:** Windows ends each line with two invisible characters (CRLF) and Linux uses one (LF). A bash script with Windows line endings fails with errors such as `bad interpreter` or `$'\r': command not found`. This file prevents that permanently, even if you edit on the Windows side.

### Step 6: Made the scripts executable (`chmod +x`)

- **What it is:** `chmod +x` gives a file permission to be run as a program.
- **Why we need it:** files copied through Windows lose that permission. Without it, `./scripts/verify.sh` fails with "Permission denied".

### Step 7: Committed and pushed

- **`git add -A`:** stages every change (added, edited and deleted files) for the next commit.
- **`git commit -m "..."`:** saves a snapshot with a message describing it. Our messages follow the "conventional commits" style (`chore:`, `feat:`, `fix:`) used in industry.
- **`git push`:** uploads your commits to GitHub.

### Step 8: GitHub login problems and how we fixed them

| Attempt | What happened | Why |
|---|---|---|
| Typed username and password | "Password authentication is not supported" | GitHub stopped accepting account passwords for Git in 2021. You must use a token (a long generated key) instead |
| Pasted a `ghp_` token | "Permission denied", with `Token scopes: none` | `ghp_` means a classic personal access token. This one had no permissions ticked, so it could read nothing and write nothing |
| Pasted a `github_pat_` token | "Permission denied" | A fine-grained token only works on the repos and permissions chosen when it was made. This one had not been given write access to this repo |
| Browser device login | **Worked** | `gh auth login -w` gives the CLI a `gho_` token with exactly the permissions requested |

- **What the GitHub CLI (`gh`) is:** GitHub's official command-line tool. We used it to log in and to handle tokens for Git automatically (`gh auth setup-git`). Later we use it to open pull requests.
- **The scopes we asked for:**
  - `repo` lets Git read and write your repositories.
  - `workflow` is required to push files in `.github/workflows/`. That folder holds our automatic CI checks, so without this scope the push is refused.
- **Why the browser did not open:** WSL cannot launch the Windows browser by itself, so you opened `https://github.com/login/device` manually and typed the code. That is normal.
- **Security note:** tokens are like passwords. Never paste a full token into a chat, an email or a file in the repo.

### Step 9: Installed the tools with `apt`

- **`sudo`:** runs a command as administrator; it asks for your Ubuntu password.
- **`apt update`:** refreshes Ubuntu's list of available software. **`apt install -y`:** installs packages and answers yes automatically.
- **Why `wslu` failed:** it is an optional helper that lets Ubuntu open the Windows browser. It is not yet available for Ubuntu 26.04, so we dropped it. Nothing depends on it.
- **Why Terraform uses the "noble" source:** HashiCorp publishes Terraform for Ubuntu 24.04 ("noble") but not yet for 26.04. The 24.04 package runs fine on 26.04.
- **Why tflint first failed with `404`:** the install script's web address had moved, so the download returned a "404 Not Found" page, which bash then tried to run. We downloaded tflint directly from its official releases page instead.
- **Why checkov and pre-commit warned about PATH:** `PATH` is the list of folders the terminal searches for programs. pipx installed them into `~/.local/bin`, which was not on the list yet. `pipx ensurepath` added it and `source ~/.bashrc` reloaded the settings.

---

## Part 3: Every tool installed, what it is, and why we need it

### The main tools

**Terraform (installed: v1.16.4)**
- **What it is:** an infrastructure as code tool from HashiCorp. You describe the infrastructure you want in `.tf` files, and Terraform works out what to create, change or delete in AWS to match.
- **What it does in this program:** builds everything in every project. For Project 1 that is about 150 resources: the network, load balancer, servers, database, cache, CDN, alarms and more.
- **Why we use it instead of clicking in the console:** it is repeatable (build, destroy and rebuild identically), reviewable (the code shows exactly what exists), versioned in Git, and it is what employers expect. The brief also requires infrastructure as code.
- **Key commands:** `terraform init` (download providers and connect to the state bucket), `terraform validate` (check the code is correct), `terraform plan` (preview changes), `terraform apply` (make the changes), `terraform destroy` (delete everything), `terraform output` (show values such as the website URL).
- **"State":** Terraform keeps a record of what it built, called state. Ours is stored in an encrypted S3 bucket per project, created by each project's `bootstrap/` folder, so it is never lost with the laptop.

**AWS CLI v2 (installed: 2.37.4)**
- **What it is:** Amazon's official command-line tool. Every button in the AWS console has an equivalent command.
- **What it does in this program:**
  1. Signs you in to AWS (`aws sso login`) and holds your temporary credentials, which Terraform uses behind the scenes.
  2. The test scripts use it to read target health, list instances, start failure experiments and read database events.
  3. You use it to check that teardown left nothing billable behind.
- **Why we need it:** Terraform and every script depend on it for credentials, and some checks can only be done from the command line.

**Session Manager plugin (installed: 1.2.835.0)**
- **What it is:** an add-on to the AWS CLI that opens a secure terminal on an EC2 server through AWS Systems Manager.
- **Why we need it:** for security, our servers have no SSH keys, no open port 22 and no public IP address. Session Manager is the only way in, and every session is logged. You will use it to look at an instance's logs if something goes wrong (`aws ssm start-session --target <instance-id>`).

**Apache JMeter (installed: 5.6.3)**
- **What it is:** a free load-testing program from the Apache Software Foundation. "Apache" is the nonprofit that publishes it.
- **What it does in this program:** pretends to be hundreds of shoppers at once. They browse the home page and catalog, trigger CPU-heavy requests and place orders for about 20 minutes, then JMeter reports response times and error rates.
- **Why we need it:** the brief says the store fails at peak traffic and names JMeter for load testing. Test T2 uses it to create a peak on purpose and prove that Auto Scaling adds servers (2 up to 6), the site stays up, and it scales back down afterwards.
- **How you use it:** through `scripts/load-test/run-jmeter.sh`. You never open JMeter directly. It needs Java to run.

### The checking tools

**checkov (installed: 3.3.19)**
- **What it is:** a security scanner for infrastructure code, made by Prisma Cloud (Palo Alto Networks).
- **What it catches:** unencrypted databases, public S3 buckets, missing logs, overly open security groups, weak TLS and hundreds of other misconfigurations.
- **Why we need it:** it finds security mistakes before they reach AWS. Project 1 currently passes 380 checks with 0 failures. Every deliberate exception is written in `.checkov.yaml` with its reason.

**tflint (installed: 0.64)**
- **What it is:** a linter (a spell-checker and grammar-checker) for Terraform.
- **What it catches:** typos, invalid instance types, undocumented variables, unused declarations and style problems that `terraform validate` does not check.
- **Why we need it:** it keeps the code clean and professional, and it runs automatically on GitHub for every pull request.

**pre-commit (installed: 4.6.2)**
- **What it is:** a tool that runs a list of checks automatically every time you `git commit`.
- **What it runs for us** (listed in `.pre-commit-config.yaml`): `terraform fmt`, `terraform validate`, tflint, checkov, gitleaks (secret detection) and basic file hygiene checks.
- **Why we need it:** it stops broken, badly formatted or insecure code, and any accidentally committed password or key, from ever reaching GitHub. You turn it on once per repo with `pre-commit install`.

### The supporting packages

| Package | What it is | Why we need it |
|---|---|---|
| `curl` | Downloads files and sends web requests from the terminal | Downloads installers; the test scripts use it to visit the store, place orders and check that the load balancer blocks direct access |
| `jq` | A JSON processor | AWS answers in JSON. The scripts use jq to pull out values such as the instance ID, AZ or order number |
| `unzip` | Extracts `.zip` files | The AWS CLI and tflint are delivered as zip files |
| `gnupg` | Checks digital signatures | Confirms the Terraform package really came from HashiCorp and was not tampered with |
| `software-properties-common` | Helper for managing software sources in apt | Needed to add HashiCorp's Terraform source to Ubuntu |
| `python3` | The Python programming language | Our storefront app is written in Python (Flask), and checkov is a Python program |
| `python3-pip`, `python3-venv` | Python's package installer and isolated environments | Let Python tools install without interfering with Ubuntu's own Python |
| `pipx` | Installs Python command-line tools, each in its own sandbox | Used to install checkov and pre-commit cleanly |
| `default-jre` | The Java runtime | JMeter is a Java program and cannot run without it |
| `default-mysql-client` | The `mysql` command for connecting to MySQL databases | Optional troubleshooting: lets you look inside the RDS database if orders or products look wrong |

### Terminal terms used along the way

| Term | Meaning |
|---|---|
| `~` | Your home folder, `/home/yusuf_adenusi` |
| `cd` | Change directory (move into a folder) |
| `ls`, `ls -a` | List files; `-a` also shows hidden files that start with a dot |
| `~/.bashrc` | The file of settings your terminal loads when it starts |
| `source ~/.bashrc` | Reload those settings without closing the terminal |
| `export AWS_PROFILE=...` | Set which AWS login the CLI and Terraform use |
| `PATH` | The list of folders the terminal searches for programs |
| `#` in a command block | A comment for humans; the computer ignores it |
| `\|` (pipe) | Sends one command's output into another (for example `curl ... \| bash`) |

---

## Part 4: What comes next (AWS account preparation), and why

| Step | What you do | What it is for |
|---|---|---|
| 1. Root MFA | Add an authenticator app to the root (email) login | The root user can do anything, including closing the account. MFA stops anyone with your password from getting in. After this, root is only used for billing settings |
| 2. IAM access to billing | Turn on "IAM user and role access to Billing information" | By default only root can see costs. This lets your everyday admin login see Cost Explorer and budgets |
| 3. $50 budget | Create a monthly cost budget with email alerts | A safety net: AWS emails you if spending heads past $50, for example if you forget to destroy a project |
| 4. IAM Identity Center | Enable it, create your user, an AdministratorAccess permission set, and assign both to your account | Creates your everyday admin login with MFA and **temporary** credentials that expire after 4 hours. This is safer than permanent access keys, which can leak |
| 5. Access portal URL | Copy the `https://d-xxxx.awsapps.com/start` link | The web address you sign in through, and what the CLI connects to |
| 6. `aws configure sso` | Connect the AWS CLI to Identity Center, profile name `aws-capstone` | Lets the CLI, Terraform and the scripts act in your account with your temporary credentials |
| 7. `export AWS_PROFILE=aws-capstone` | Save the profile choice in `~/.bashrc` | So every command uses the right login without typing `--profile` each time |
| 8. `aws sts get-caller-identity` | Ask AWS "who am I?" | Confirms the login works: it shows your account number and the AdministratorAccess role |
| 9. `aws sso login` | Run whenever credentials expire | Renews your temporary credentials (every 4 hours) |

---

## Part 5: The files in the repository and why each exists

### Root of the repo (shared tooling, used by all 14 projects)

| File or folder | What it is | Why it exists |
|---|---|---|
| `README.md` | The front page of the repo | Lists all 14 projects and their status, and explains the standards; it is what visitors see first |
| `.gitignore` | A list of files Git must never upload | Keeps out Terraform state, `terraform.tfvars` (your email), `backend.hcl` (account ID), zips and temporary files, so no private data reaches GitHub |
| `.gitattributes` | Line-ending rules | Keeps scripts working (Step 5) |
| `.editorconfig` | Formatting rules for editors | Consistent indentation and line endings in VS Code and other editors |
| `.pre-commit-config.yaml` | The list of checks pre-commit runs | Automatic quality and security checks before every commit |
| `.tflint.hcl` | tflint's settings | Which lint rules apply to all projects |
| `.checkov.yaml` | checkov's settings | The documented list of deliberately skipped checks, each with its reason |
| `.github/workflows/terraform-ci.yml` | A GitHub Actions workflow | Runs fmt, validate, tflint, checkov and gitleaks on GitHub for every pull request; free and needs no AWS access |
| `docs/capstone-strategy.md` | The program standards | How every project is planned, built, checked, tested, torn down and documented |
| `docs/workstation-setup.md` | Laptop setup guide | Install commands for all tools, and the Day 0 AWS steps |
| `docs/setup-journal.md` | This document | The record of what was done and why |

### Inside `project-01-ha-ecommerce/`

| File or folder | What it is | Why it exists |
|---|---|---|
| `README.md` | Project front page | Requirements mapped to services, how to deploy, test and destroy, and the cost |
| `bootstrap/` | A small separate Terraform stack | Creates Project 1's own encrypted, versioned S3 bucket for Terraform state, and writes `backend.hcl` |
| `versions.tf` | Terraform and provider versions, and the S3 backend | Everyone uses the same versions; state is stored in S3, not on the laptop |
| `providers.tf` | AWS provider settings | Region us-east-2, a second connection to us-east-1 (CloudFront metrics live there), and tags added to every resource |
| `variables.tf` | Every setting you can change | Instance sizes, counts, cost toggles, alert email; each one is documented and validated |
| `locals.tf` | Derived values | Names, AZs, subnet ranges and tags calculated once and reused |
| `network.tf` | VPC, subnets, gateways, routes, flow logs | The private network across two AZs that everything runs in |
| `security_groups.tf` | Firewall rules | The chain CloudFront to ALB to app to database and cache |
| `kms.tf` | Encryption keys | Encrypts the database, cache, secrets, logs and notifications |
| `secrets.tf` | Secrets Manager entries | Stores the Redis password and the CloudFront secret header value, never in code |
| `iam.tf` | Roles and permissions | Least-privilege permissions for the servers and AWS services |
| `s3.tf` | Four S3 buckets and their contents | Static files for CloudFront, the app bundle, logs and the audit trail |
| `alb.tf` | Application Load Balancer | Spreads traffic across healthy servers in both AZs; blocks anyone who is not CloudFront |
| `compute.tf` | Launch template and Auto Scaling group | Builds identical servers, replaces failed ones and scales from 2 to 6 |
| `database.tf` | RDS MySQL Multi-AZ and a read replica | The store's database with automatic failover and read offloading |
| `cache.tf` | ElastiCache Redis | Keeps the product catalog in memory for speed; fails over automatically |
| `cdn.tf` | CloudFront distribution | Global HTTPS front door, edge caching and the maintenance page |
| `monitoring.tf` | Alarms, dashboard, SNS topics, event rules | Detects problems and emails you |
| `cloudtrail.tf` | Audit trail | Records every action taken in the account |
| `fis.tf` | Fault Injection Service experiments | Breaks things on purpose (kill one AZ's servers, fail over the database) to prove recovery works |
| `outputs.tf` | Values printed after deploy | The website URL, dashboard link and IDs the scripts need |
| `terraform.tfvars.example` | Example settings | You copy it to `terraform.tfvars` and add your email; the copy is never uploaded |
| `backend.hcl.example` | Example state settings | Shows what bootstrap generates; the real file is never uploaded |
| `templates/user_data.sh.tftpl` | The server startup script | Installs nginx, Python and the CloudWatch agent, downloads the app, and starts it on every new server |
| `app/` | The storefront application (Python Flask) | A real shop with products and orders, showing which server and AZ answered each request, so failover is visible |
| `scripts/verify.sh` | Automated post-deploy checks | Prints PASS or FAIL for every part of the architecture |
| `scripts/watch-availability.sh` | Downtime monitor | Reads and writes every second during failure tests and records the results in a CSV |
| `scripts/load-test/` | JMeter plan and runner | Test T2: proves Auto Scaling under load |
| `scripts/chaos/` | Failure test runners | Tests T3, T4 and T5: AZ loss, database failover and cache failover |
| `docs/architecture.md` | Design document | The problem, the design, how each failure is handled, decisions and cost |
| `docs/testing.md` | Test plan and results table | What each test proves, how to run it, what to expect; you fill in the results |
| `docs/troubleshooting.md` | Fixes for common problems | Including the three issues named in the brief |
| `docs/RUNBOOK.md` | Step-by-step runbook | Every action from laptop to merged project |
| `evidence/` | Screenshots and test output | Proof for the write-up |

---

## Part 6: Documents delivered so far

| Document | What it is for |
|---|---|
| `aws-personal-project-p01.zip` | All the repo files: the shared tooling plus Project 1 |
| `Project1_AWS_Services_Guide.docx` | The 28 AWS services used in Project 1: what each is, why we use it, how it is configured, exam tips and cost |
| `AWS_Services_Study_Guide.pdf` | 119 AWS services in 13 categories, with 10 comparison cheat sheets, for SAA-C03 study |
| `Project1_Runbook.docx` | Every step from an empty laptop to a merged, tagged Project 1 |
| `Setup_Journal.docx` | This record |
