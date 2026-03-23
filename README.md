# Philips Labs — AWS EC2 Self-Hosted GitHub Actions Runners

Auto-scaling, ephemeral GitHub Actions runners on AWS EC2 spot instances using the [Philips Labs terraform-aws-github-runner](https://github.com/philips-labs/terraform-aws-github-runner) module ([Terraform Registry](https://registry.terraform.io/modules/philips-labs/github-runner/aws/latest)). No Kubernetes required.

GitHub account: **getdzidon** — `https://github.com/getdzidon`

---

## How it works

```
Manual steps (one-time)  →  push to main  →  deploy-runner.yaml runs  →  runners auto-scale on demand
```

Once the manual steps below are done and the code is pushed to `main`, the `deploy-runner.yaml` pipeline deploys all infrastructure via Terraform. GitHub webhook events trigger Lambda functions that spin up EC2 spot instances as runners on demand and terminate them after each job.

---

## Architecture

```
GitHub webhook event (workflow_queued)
        │
        ▼
  API Gateway → Lambda (webhook) → SQS queue
                                        │
                                        ▼
                                  Lambda (scale-up)
                                        │
                                        ▼
                                  EC2 spot instance (ephemeral runner)
                                        │
                                        ▼
                                  Job completes → instance terminates
                                        │
                                        ▼
                                  Lambda (scale-down) — checks every minute
```

**Key components created by the module:**
- API Gateway — receives GitHub webhook events
- Lambda functions — webhook handler, scale-up, scale-down, binary syncer, AMI housekeeper, termination watcher
- SQS queues — job queue with dead-letter queue
- EC2 launch template — spot instances with encrypted EBS
- SSM parameters — runner configuration and tokens
- IAM roles — least-privilege for Lambdas and EC2 instances
- CloudWatch log groups — Lambda and runner logs

---

## Project structure

```
philips-labs-runner/
├── .github/
│   ├── workflows/
│   │   ├── deploy-runner.yaml    # Terraform deploy/destroy pipeline
│   │   └── example-job.yaml      # Example job running ON the self-hosted runner
│   └── dependabot.yml
├── terraform/
│   ├── providers.tf              # AWS provider config
│   ├── versions.tf               # Terraform and provider versions, S3 backend
│   ├── variables.tf              # Input variables
│   ├── terraform.tfvars          # Default variable values (non-sensitive only)
│   ├── vpc.tf                    # VPC with public/private subnets and NAT
│   ├── runners.tf                # Philips Labs module + webhook-github-app submodule
│   └── outputs.tf                # Webhook endpoint and other outputs
├── .gitignore
└── README.md
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| terraform | >= 1.3.0 | [docs](https://developer.hashicorp.com/terraform/install) |
| aws cli | >= 2.x | [docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| An AWS account | — | With permissions for EC2, Lambda, API Gateway, SQS, IAM, SSM, VPC, CloudWatch |
| A GitHub account | — | `https://github.com/getdzidon` |

---

## ⚠️ Manual steps — do these first, in order

Complete all of them before pushing to `main`.

---

### 🔵 Step 1 — Create a GitHub App

The Philips Labs module uses a GitHub App (not a PAT) to manage runner registration and receive webhook events.

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name**: `philips-labs-runner` (must be globally unique — append your username if taken)
   - **Homepage URL**: `https://github.com/getdzidon`
   - **Webhook URL**: `https://example.com` (placeholder — updated after first deploy)
   - **Webhook secret**: Generate a strong secret and save it — you need it later
3. Set **Permissions**:
   - Repository: `Actions: Read-only`, `Administration: Read & Write`, `Checks: Read-only`, `Metadata: Read-only`
   - Organization: `Self-hosted runners: Read & Write`
4. Under **Subscribe to events**: check `Workflow job`
5. Under **Where can this GitHub App be installed?** select *Only on this account*
6. Click **Create GitHub App**
7. Note the **App ID** shown at the top of the next page

**Generate a private key:**

1. Scroll down to **Private keys** → click **Generate a private key**
2. A `.pem` file downloads — keep it safe, you cannot re-download it

**Base64-encode the private key:**

```bash
# Linux/macOS
base64 -w 0 < your-app.private-key.pem

# Windows (PowerShell)
[Convert]::ToBase64String([IO.File]::ReadAllBytes("your-app.private-key.pem"))
```

**Install the App:**

1. In the left sidebar click **Install App** → click **Install** next to your account
2. Choose *All repositories* or select specific repos → click **Install**

You now have three values you will need in the steps below:
- `App ID`
- `Base64-encoded private key`
- `Webhook secret`

---

### 🟢 Step 2 — Create the GitHub Actions OIDC provider and IAM role

The deploy pipeline authenticates to AWS via OIDC — no static credentials.

```bash
# 1. Add GitHub OIDC provider to AWS (one time per account — skip if already done)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com

# 2. Create trust policy
cat > /tmp/github-oidc-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:getdzidon/philips-labs-runner:*"
      }
    }
  }]
}
EOF

# 3. Create the role
aws iam create-role \
  --role-name github-actions-philips-runner-role \
  --assume-role-policy-document file:///tmp/github-oidc-trust.json

# 4. Attach permissions (Terraform needs broad access to create all resources)
aws iam attach-role-policy \
  --role-name github-actions-philips-runner-role \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

> **Note:** `AdministratorAccess` is used here for simplicity. In production, scope this down to only the services Terraform needs: EC2, Lambda, API Gateway, SQS, IAM, SSM, VPC, CloudWatch, S3.

Note the role ARN — you need it in Step 3.

---

### 🟡 Step 3 — Set GitHub Actions secrets

Go to **GitHub → your repo → Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Value |
|--------|-------|
| `AWS_IAM_ROLE_ARN` | ARN of the role from Step 2, e.g. `arn:aws:iam::<ACCOUNT_ID>:role/github-actions-philips-runner-role` |
| `AWS_REGION` | e.g. `eu-central-1` |
| `GH_APP_ID` | App ID from Step 1 |
| `GH_APP_KEY_BASE64` | Base64-encoded private key from Step 1 |
| `GH_APP_WEBHOOK_SECRET` | Webhook secret from Step 1 |

> Do not add `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` — OIDC is used instead.

---

### 🟠 Step 4 — Update the GitHub App webhook URL (after first deploy)

After the first `terraform apply` completes (either via pipeline or locally), it outputs the **API Gateway webhook endpoint**.

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → your app**
2. Replace the placeholder webhook URL (`https://example.com`) with the API Gateway endpoint from the Terraform output
3. Ensure **Webhook Active** is checked
4. Click **Save changes**

> The `webhook-github-app` submodule can automate this on subsequent applies, but the first deploy requires a manual update since the endpoint doesn't exist yet.

---

### 🟣 Step 5 — Install the Renovate GitHub App (optional but recommended)

Renovate automatically opens PRs when Terraform module or provider versions are updated.

1. Go to [github.com/apps/renovate](https://github.com/apps/renovate)
2. Click **Install** and grant access to this repository

Dependabot (for GitHub Actions and Terraform version updates) is built into GitHub and requires no installation.

---

## ✅ What happens automatically after you push to main

**`deploy-runner.yaml`** — runs when `terraform/**` or the workflow file changes:

1. Checks out the repo
2. Authenticates to AWS via OIDC (using `AWS_IAM_ROLE_ARN` from Step 2)
3. Runs `terraform init` and `terraform plan`
4. Applies the plan — provisions VPC, Lambda functions, API Gateway, SQS queues, EC2 launch template, IAM roles, SSM parameters, CloudWatch log groups
5. Prints the webhook endpoint (needed for Step 4 on first deploy)

**When a GitHub Actions job is queued:**

1. GitHub sends a `workflow_job` webhook event to the API Gateway
2. The webhook Lambda validates the event and puts it on the SQS queue
3. The scale-up Lambda picks up the message and launches an EC2 spot instance
4. The instance boots, registers as a runner, picks up the job
5. Job completes → instance terminates
6. The scale-down Lambda checks every 5 minutes and cleans up any stale instances

**Version updates are also automated:**
- Dependabot opens weekly PRs for GitHub Actions and Terraform version bumps
- Renovate can be configured for additional dependency tracking

---

## Verify installation

After the first deploy and webhook URL update:

1. Trigger the `example-job.yaml` workflow via `workflow_dispatch`
2. Watch the GitHub Actions run — it should be picked up by a self-hosted runner
3. Check AWS CloudWatch logs for the webhook and scale-up Lambda functions

```bash
# Check Lambda functions
aws lambda list-functions --query "Functions[?starts_with(FunctionName, 'gh-runners')].FunctionName" --output table

# Check if any runner instances are running
aws ec2 describe-instances \
  --filters "Name=tag:ghr:environment,Values=gh-runners" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name}" \
  --output table
```

---

## Using the runners in other repositories

> **Org vs personal account:** The `enable_organization_runners` variable in `terraform.tfvars` controls whether runners register at the organization level or repository level. Organization runners require a GitHub **organization** account — personal accounts (e.g. `github.com/username`) must set this to `false`. If set to `true` on a personal account, the scale-up Lambda will silently ignore webhook events and runners will never start.

**Repo-level runners** (`enable_organization_runners = false`):
- Runners are registered to the repo where the GitHub App is installed
- Only workflows in that repo can use them
- Install the GitHub App on each repo that needs runners

**Org-level runners** (`enable_organization_runners = true`):
- Runners are registered at the organization level
- Any repo in the org can use them (if the GitHub App has access)
- Requires a GitHub organization account

```yaml
jobs:
  build:
    runs-on: [self-hosted, ec2, spot]
    steps:
      - uses: actions/checkout@v6
      - run: echo "Running on EC2 spot runner!"
```

The labels `self-hosted`, `ec2`, and `spot` must match the `runner_extra_labels` configured in `terraform.tfvars`.

Full deploy example (in your app repo, not this repo):

```yaml
# .github/workflows/deploy-app.yaml
name: Deploy App

on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    runs-on: [self-hosted, ec2, spot]

    steps:
      - uses: actions/checkout@v6

      - name: Authenticate to AWS via OIDC
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_IAM_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Deploy
        run: |
          echo "Running on self-hosted EC2 spot runner!"
          # Your deployment commands here
```

---

## Autoscaling

| Setting | Value | Description |
|---------|-------|-------------|
| `runners_maximum_count` | 5 | Hard cap on concurrent runners |
| `idle_config` | 1 runner, Mon-Fri 8-18 UTC | Warm pool during business hours |
| `scale_down_schedule_expression` | Every 5 minutes | How often the scale-down Lambda checks for idle instances |
| `delay_webhook_event` | 5 seconds | Delay before scale-up Lambda processes the webhook event |
| Runner lifecycle | Ephemeral | Instance is terminated after each job |
| Instance type | Spot | Up to 90% savings vs on-demand |

To change limits, edit `terraform/runners.tf` or `terraform/terraform.tfvars` and push to `main`.

### Ephemeral runners

`enable_ephemeral_runners = true` means each EC2 instance handles exactly one job and terminates immediately after. This ensures:
- No state leakage between jobs (clean environment every time)
- No stale runners sitting idle after a job completes
- Scale to zero when no jobs are queued

The tradeoff is **startup time** — each job triggers a cold boot of a new EC2 instance (2-3 minutes) unlike GitHub-hosted runners (pre-warmed, instant) or ARC on Kubernetes (pod scheduling, seconds). This is the fundamental difference with EC2-based runners.

### Warm pool (idle runners)

The `idle_config` setting pre-warms idle runner instances on a cron schedule so jobs during those hours get picked up instantly without waiting for a cold boot:

```hcl
idle_config = [{
  cron      = "* * 8-18 * * 1-5"   # Mon-Fri, 8am-6pm UTC
  timeZone  = "UTC"
  idleCount = 1                      # Keep 1 idle runner ready
}]
```

- **Inside the cron window** — 1 idle instance stays running and picks up jobs instantly. If it handles a job and terminates (ephemeral), a new idle instance is created to maintain the count
- **Outside the cron window** — no idle instances. Jobs trigger a cold boot (2-3 minutes)
- **Cost impact** — an idle `t3.medium` spot instance costs ~$0.013/hr. Keeping 1 warm for 10 hours/day × 5 days = ~$2.80/month

To adjust, change the cron expression, time zone, or idle count in `terraform/runners.tf`.

### Custom AMI (reduce startup time)

The default Amazon Linux AMI installs the GitHub Actions runner agent and dependencies at boot, which adds to startup time. Building a custom AMI with pre-installed tools reduces cold boot from ~3 minutes to ~1 minute.

**How it works:**
1. Packer launches a temporary EC2 instance from a base Amazon Linux 2023 AMI
2. Runs provisioning scripts that install packages, the GitHub runner agent, and any custom tools you specify
3. Creates a snapshot of the instance as a new AMI stored in your AWS account's AMI registry
4. Terminates the temporary instance
5. The AMI name follows the format `github-runner-al2023-x86_64-YYYYMMDDhhmm` — the timestamp suffix is why the `ami_filter` uses a `*` wildcard to always match the latest build

When the module launches a runner, it uses `ami_filter` to find the most recent AMI matching the pattern, so you can rebuild the AMI anytime and runners will automatically use the latest version.

**Install Packer:**

```bash
# Windows (Chocolatey)
choco install packer

# Windows (Scoop)
scoop install packer

# Windows (manual) — download from https://developer.hashicorp.com/packer/install
# Extract packer.exe and add to PATH

# macOS (Homebrew)
brew install packer

# Linux (Ubuntu/Debian)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install packer

# Linux (Amazon Linux / RHEL)
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y packer

# Verify
packer version
```

**AWS credentials:**

Packer uses your local AWS credentials to launch a temporary EC2 instance, create the AMI, and terminate the instance. Ensure you have AWS CLI installed and configured:

```bash
# Configure credentials (if not already done)
aws configure

# Verify access
aws sts get-caller-identity
```

**Build the AMI:**

```bash
# Clone the module repo
git clone https://github.com/philips-labs/terraform-aws-github-runner.git
cd terraform-aws-github-runner/images/linux-al2023

# Initialize Packer plugins
packer init .

# Validate the template
packer validate .

# Build the AMI (takes ~5-10 minutes)
packer build -var 'region=eu-central-1' github_agent.linux.pkr.hcl
```

**Pre-install custom tools:**

The Packer template has a `custom_shell_commands` variable. Pass additional install commands to bake tools into the AMI:

```bash
packer build \
  -var 'region=eu-central-1' \
  -var 'custom_shell_commands=["sudo dnf install -y nodejs npm", "sudo dnf install -y python3 python3-pip", "sudo pip3 install awscli"]' \
  github_agent.linux.pkr.hcl
```

The base template already installs: `docker`, `jq`, `git`, `amazon-cloudwatch-agent`, and the GitHub Actions runner agent. Add any tools your workflows need (Node.js, Python, Go, build tools, etc.) via `custom_shell_commands`.

**Reference the AMI in `runners.tf`:**

The following block is commented out in `runners.tf`. Uncomment it after building your custom AMI:

```hcl
# # Custom AMI — uncomment to use a pre-built AMI instead of the default
# # Build with: packer build -var 'region=eu-central-1' github_agent.linux.pkr.hcl
# ami_filter = {
#   name  = ["github-runner-al2023-x86_64-*"]
#   state = ["available"]
# }
# ami_owners = ["<YOUR_ACCOUNT_ID>"]
# enable_userdata = false
```

> `enable_userdata = false` is required when using a custom AMI — the AMI already has the runner agent and start script baked in, so the user-data bootstrap is skipped.

> The `enable_ami_housekeeper = true` setting automatically cleans up AMIs older than 14 days, so old custom AMIs don't accumulate.

---

## Features

- **Scale to zero** — no runners running when no jobs are queued
- **Spot instances** — up to 90% cost savings vs on-demand, with multiple instance types for availability
- **Ephemeral** — fresh instance per job, no state leakage between runs
- **Warm pool** — configurable idle runners during business hours for faster job pickup
- **Spot termination watcher** — gracefully handles spot interruptions
- **AMI housekeeper** — automatically cleans up old AMIs
- **SSM access** — debug runners via AWS Systems Manager (no SSH keys needed)
- **CloudWatch logs** — Lambda and runner logs centralized
- **EventBridge** — event-driven architecture for webhook processing
- **Encrypted EBS** — 30GB gp3 volumes with encryption at rest

---

## Cost estimate (eu-central-1)

| Component | Cost |
|-----------|------|
| NAT Gateway | ~$32/month + data transfer |
| Lambda functions | Negligible (free tier covers most usage) |
| API Gateway | Negligible |
| SQS | Negligible |
| EC2 spot (t3.medium) | ~$0.013/hr (only while jobs run) |
| CloudWatch logs | ~$0.50/GB ingested |

For light CI usage (a few jobs per day), expect **~$35-40/month** — mostly the NAT Gateway. For heavy usage, EC2 spot costs scale linearly.

---

## .gitignore

| Pattern | What it blocks |
|---------|----------------|
| `*.pem` | GitHub App private key files |
| `*.key` | Any raw key files |
| `.env` | Local environment variable files |
| `terraform/.terraform/` | Terraform working directory (provider binaries, module copies) |
| `terraform/.terraform.lock.hcl` | Provider lock file |
| `terraform/*.tfplan` | Terraform plan files |
| `*.zip` | Lambda zip files |

---

## Troubleshooting

**Runners not scaling up**

Check the webhook Lambda CloudWatch logs:
```bash
aws logs tail /aws/lambda/gh-runners-webhook --follow
```
Most common causes:
- `enable_organization_runners = true` on a personal account — set to `false` (see "Using the runners" section above)
- The GitHub App webhook URL does not match the API Gateway endpoint
- The webhook secret does not match between GitHub App and Terraform
- The GitHub App is not installed on the target repository

**Spot capacity unavailable**

The module uses multiple instance types for diversity. If you see `InsufficientInstanceCapacity` errors:
- Add more instance types to `instance_types` in `terraform.tfvars`
- Consider enabling on-demand failover by adding to `runners.tf`:
  ```hcl
  enable_runner_on_demand_failover_for_errors = ["InsufficientInstanceCapacity"]
  ```

**Runner takes too long to boot**

Default boot time allowance is 5 minutes. If runners time out before registering:
- Increase via `runner_boot_time_in_minutes` in `runners.tf`
- Build a custom AMI with pre-installed dependencies (see "Custom AMI" section above)

**SSM parameter exceeds 4096 character limit**

The scale-up Lambda writes runner tokens to SSM at runtime. If your account uses Standard tier (4096 char limit), this can fail. Set the account-level default to Advanced tier:
```bash
aws ssm update-service-setting \
  --setting-id "arn:aws:ssm:<REGION>:<ACCOUNT_ID>:servicesetting/ssm/parameter-store/default-parameter-tier" \
  --setting-value "Advanced"
```
Advanced tier costs $0.05/parameter/month.

**Lambda concurrency error (UnreservedConcurrentExecution below minimum)**

New AWS accounts have a low Lambda concurrency quota (as low as 10). The module reserves concurrency per Lambda, which can exceed the limit. Either:
- Request a quota increase in AWS Service Quotas → Lambda → Concurrent executions
- Set `scale_up_reserved_concurrent_executions = -1` and `pool_lambda_reserved_concurrent_executions = -1` in `runners.tf` to disable reserved concurrency

**Webhook returns 401/403**

The webhook secret in the GitHub App settings must exactly match the `GH_APP_WEBHOOK_SECRET` GitHub Actions secret. Regenerate both if unsure.

**Terraform destroy fails on Lambda functions**

Lambda functions with active CloudWatch log groups can sometimes block deletion. If destroy hangs:
```bash
terraform destroy -target=module.runners
terraform destroy
```

**Pipeline fails at Terraform plan**

Ensure all three GitHub App secrets are set correctly:
- `GH_APP_ID` — numeric App ID (not the app name)
- `GH_APP_KEY_BASE64` — the full base64-encoded `.pem` file (not the raw PEM content)
- `GH_APP_WEBHOOK_SECRET` — the webhook secret string

---

## Uninstall

**Via the pipeline (recommended):**

1. Go to **Actions → Deploy Philips Labs Runner → Run workflow**
2. Select `destroy` from the dropdown
3. Click **Run workflow**

**Locally:**

```bash
cd terraform
terraform destroy
```

This removes all AWS resources: VPC, Lambda functions, API Gateway, SQS queues, EC2 launch templates, IAM roles, SSM parameters, and CloudWatch log groups.

After destroying, you can also:
- Delete the GitHub App: **GitHub → Settings → Developer settings → GitHub Apps → your app → Delete**
- Remove the OIDC role: `aws iam delete-role --role-name github-actions-philips-runner-role`

---

## Comparison: ARC on EKS vs Philips Labs on EC2

| | ARC on EKS | Philips Labs on EC2 |
|---|---|---|
| Infrastructure | EKS cluster + node groups | Lambda + API Gateway + SQS |
| Base cost | ~$73/month (EKS control plane) | ~$35/month (NAT Gateway) |
| Scaling | Kubernetes pod scheduling (seconds) | EC2 fleet API (minutes) |
| Runner isolation | Pod-level | Instance-level (stronger) |
| Boot time | Seconds (pod) | Minutes (EC2 instance) |
| Complexity | High (K8s knowledge required) | Medium (Terraform only) |
| Best for | Teams already on Kubernetes | Teams wanting simplicity and cost savings |
