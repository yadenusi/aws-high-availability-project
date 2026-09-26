# Workstation Setup and AWS Account Preparation

This guide gets a laptop ready to build, check, deploy and test every project in this repo. Do it once. Budget about 60 to 90 minutes including the AWS account steps.

## 1. Choose your shell

**Windows:** install WSL2 with Ubuntu and do all command line work inside it. Every script in this repo is bash, and Terraform, the AWS CLI and the linters behave identically there.

```powershell
# PowerShell as Administrator
wsl --install -d Ubuntu-24.04
# Reboot, open "Ubuntu", create your Linux user
```

Install VS Code on Windows itself and add the **WSL** extension, then open projects with `code .` from the Ubuntu terminal.

**macOS:** use the built-in Terminal or iTerm2 with Homebrew:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## 2. Install the tools

### Ubuntu (WSL2)

```bash
sudo apt update && sudo apt install -y git unzip curl jq gnupg software-properties-common \
  python3 python3-pip python3-venv pipx default-jre mysql-client

# Terraform (HashiCorp apt repo)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip

# Session Manager plugin (shell access to EC2 without SSH keys)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o ssm.deb
sudo dpkg -i ssm.deb && rm ssm.deb

# GitHub CLI
sudo apt install -y gh

# Python based tools
pipx ensurepath
pipx install pre-commit
pipx install checkov

# tflint, terraform-docs, gitleaks, infracost
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
curl -sSLo tfdocs.tar.gz https://terraform-docs.io/dl/v0.20.0/terraform-docs-v0.20.0-linux-amd64.tar.gz \
  && tar -xzf tfdocs.tar.gz terraform-docs && sudo mv terraform-docs /usr/local/bin/ && rm tfdocs.tar.gz
curl -sSfL https://raw.githubusercontent.com/gitleaks/gitleaks/master/scripts/install.sh | sudo sh -s -- -b /usr/local/bin
curl -fsSL https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | sh

# Apache JMeter (load testing, needs Java from default-jre above)
JMETER=5.6.3
curl -sSLO https://dlcdn.apache.org/jmeter/binaries/apache-jmeter-${JMETER}.tgz
tar -xzf apache-jmeter-${JMETER}.tgz -C "$HOME" && rm apache-jmeter-${JMETER}.tgz
echo "export PATH=\"\$HOME/apache-jmeter-${JMETER}/bin:\$PATH\"" >> ~/.bashrc
```

### macOS (Homebrew)

```bash
brew install git gh jq python@3.12 pipx mysql-client tflint terraform-docs gitleaks infracost jmeter awscli
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
brew install --cask session-manager-plugin visual-studio-code postman
pipx ensurepath && pipx install pre-commit && pipx install checkov
```

### Windows side (optional GUI tools)

```powershell
winget install Microsoft.VisualStudioCode Postman.Postman Oracle.MySQLWorkbench
```

### VS Code extensions

```bash
code --install-extension hashicorp.terraform
code --install-extension amazonwebservices.aws-toolkit-vscode
code --install-extension ms-python.python
code --install-extension redhat.vscode-yaml
code --install-extension davidanson.vscode-markdownlint
code --install-extension eamodio.gitlens
```

## 3. Verify the toolchain

Every line should print a version:

```bash
git --version
gh --version | head -1
terraform version | head -1        # 1.11 or newer
aws --version
session-manager-plugin --version
python3 --version
jq --version
tflint --version | head -1
checkov --version
pre-commit --version
terraform-docs --version
gitleaks version
infracost --version
jmeter --version 2>/dev/null | tail -1
mysql --version
```

## 4. AWS account preparation (Day 0)

These steps are manual because they need the root user or they must exist before Terraform can run. Project 5 later rebuilds the full account and IAM baseline in code.

1. **Secure root.** Sign in as root, go to *Security credentials*, and assign an MFA device. Delete any root access keys. From here on, root is only for the billing steps below.
2. **Allow IAM users to see billing.** As root: *Account* page, then *IAM user and role access to Billing information*, then *Activate*.
3. **Create your admin identity (recommended: IAM Identity Center).**
   - Open IAM Identity Center in `us-east-2` and enable it.
   - Create a user for yourself, then a permission set `AdministratorAccess` with a 4 hour session.
   - Assign the user and permission set to your account.
   - Sign in through the access portal URL once and register MFA.
4. **Configure the CLI** with short-lived credentials:
   ```bash
   aws configure sso
   #   SSO session name: capstone
   #   SSO start URL: <your access portal URL>
   #   SSO region: us-east-2
   #   Default region: us-east-2
   #   Profile name: aws-capstone
   aws sso login --profile aws-capstone
   export AWS_PROFILE=aws-capstone
   aws sts get-caller-identity
   ```
   Add `export AWS_PROFILE=aws-capstone` to `~/.bashrc` so every project uses it.
5. **Budget guardrail.** *Billing and Cost Management*, then *Budgets*, then create a monthly cost budget of **$50** with email alerts at 50%, 80% and 100% (actual) and 100% (forecasted). Enable **Cost Explorer**.
6. **Quotas.** In *Service Quotas* confirm: EC2 *Running On-Demand Standard instances* is at least 16 vCPU, and *EC2-VPC Elastic IPs* is at least 5.

## 5. Connect the repo

```bash
gh auth login
gh repo clone yadenusi/aws-personal-project
cd aws-personal-project
pre-commit install
infracost auth login
```

## 6. Everyday commands

```bash
aws sso login --profile aws-capstone     # when credentials expire
pre-commit run --all-files               # all static checks
terraform plan -out tfplan               # inside a project folder
infracost breakdown --path .             # monthly cost estimate of the stack in this folder
```
