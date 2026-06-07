# Setup Guide

This guide takes you from a fresh computer to a working calculator — first on
your own machine, then on AWS. It assumes **no prior cloud experience**. Every
command tells you what to expect, and a [troubleshooting](#troubleshooting)
section at the end covers the bumps people hit.

If you just want the short version, the [README](README.md) has a quick start.
This file is the patient, explain-everything version.

---

## Table of contents

1. [Install the software](#1-install-the-software)
2. [Get the code](#2-get-the-code)
3. [Run it locally](#3-run-it-locally-free-no-aws)
4. [Deploy to AWS](#4-deploy-to-aws)
5. [Clean up](#5-clean-up)
6. [Troubleshooting](#troubleshooting)
7. [Difficulties faced (and how they were solved)](#difficulties-faced-and-how-they-were-solved)

---

## 1. Install the software

You only do this once. After each install, run the "check" command to confirm
it worked — if it prints a version number, you're good.

| Software | What it is, in plain English | Download | Check it works |
|----------|------------------------------|----------|----------------|
| **Node.js** | The program that runs JavaScript code outside a browser. Comes with `npm`, which installs code libraries. | https://nodejs.org (pick the "LTS" version) | `node -v` and `npm -v` |
| **Docker** | Runs small, isolated "containers". We use it to run a free local copy of the database. | https://docs.docker.com/get-docker | `docker -v` |
| **Terraform** | Lets you create cloud infrastructure by writing files instead of clicking around AWS. | https://developer.hashicorp.com/terraform/install | `terraform -v` |
| **AWS CLI** | A command-line way to talk to your AWS account (and to the local database). | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html | `aws --version` |
| **Git** | Version control; how the code is stored and shared. | https://git-scm.com | `git --version` |

### Connect the AWS CLI to your account

You need an AWS account and a set of **access keys** for an IAM user (not your
root account — see [the IAM note](#a-note-on-iam-users) below). Once you have
the keys:

```bash
aws configure
```

It will ask for four things:

- **AWS Access Key ID** — from your IAM user
- **AWS Secret Access Key** — from your IAM user
- **Default region** — use `eu-north-1` (Stockholm) for this project
- **Default output format** — type `json`

Confirm it worked:

```bash
aws sts get-caller-identity
```

If it prints your account number and a user name, you're connected.

> **Tip:** set a **billing alarm** in the AWS console (Billing -> Budgets) for,
> say, $5. This project costs essentially nothing, but the alarm is a safety net.

---

## 2. Get the code

If you're starting from this repository:

```bash
git clone https://github.com/<your-username>/aws-lambda-dynamodb-terraform-calculator.git
cd aws-lambda-dynamodb-terraform-calculator
```

> **Why is there no `node_modules` folder?** That folder holds the downloaded
> code libraries. It's intentionally *not* stored in the repo because it's large
> and easy to recreate — you'll rebuild it in the next step with `npm install`.
> The list of what to install lives in `lambda/package.json`.

---

## 3. Run it locally (free, no AWS)

This proves the calculator works on your machine before you touch the cloud.

### Step 3a — Start the local database

From the project root:

```bash
docker compose up -d
```

This downloads (first time only) and starts **DynamoDB Local** — a real,
AWS-made copy of the database that runs on your computer at
`http://localhost:8000`. The `-d` means "run in the background."

### Step 3b — Install the libraries

```bash
cd lambda
npm install
```

This reads `package.json` and creates the `node_modules` folder with the AWS
libraries the code needs.

### Step 3c — Run one calculation

```bash
node local-test.js
```

Expected output:

```
Table created.
Status: 200 Body: {"message":"Success","input":{"operation":"add","a":7,"b":5},"result":12,"savedRecordId":"..."}
```

`"result":12` means the calculator logic **and** the database write both work.

### Step 3d — Turn it into a real API you can call

```bash
npm install express        # a small library to run a local web server
node local-server.js       # leave this running
```

You'll see `Local API running on http://localhost:3000`. Now open a **second
terminal** and send it a request:

```bash
curl -X POST http://localhost:3000/calculate \
  -H "Content-Type: application/json" \
  -d '{"operation":"add","a":7,"b":5}'
```

You should get back JSON with `"result":12`. Try `subtract`, `multiply`,
`divide`, and even `divide` by zero to watch the error handling work.

### Step 3e — (Optional) Look inside the local database

```bash
aws dynamodb scan \
  --table-name simple-calculator-history \
  --endpoint-url http://localhost:8000
```

You'll see every calculation you've made. The `--endpoint-url` flag is what
tells the CLI to look at your *local* database instead of AWS.

When you're done locally, stop the database with `docker compose down`.

---

## 4. Deploy to AWS

Now the same code goes to the real cloud.

### A note on IAM users

**Never use your AWS root account for daily work.** Create an **IAM user** in
the AWS console, give it access keys, and use those. Think of the root account
like the master key to a building — you keep it locked away and use a normal
key day to day.

### Permissions your IAM user needs

Terraform runs *as you*, so your user needs permission to create the resources.
The simplest approach for a personal/learning account is to attach these four
AWS-managed policies to your user (IAM -> Users -> your user -> Add permissions
-> Attach policies directly):

- `AmazonDynamoDBFullAccess`
- `AWSLambda_FullAccess` *(note the underscore)*
- `AmazonAPIGatewayAdministrator`
- `IAMFullAccess`

> **The one that trips everyone up:** when Terraform creates the Lambda, it must
> *hand* an IAM role to the Lambda service — an action called `iam:PassRole`. If
> it's missing you'll see `is not authorized to perform: iam:PassRole`.
> `IAMFullAccess` includes it, so the four policies above cover you.

### Deploy in three commands

```bash
# 1. Make sure libraries are installed (they get zipped and uploaded)
cd lambda && npm install && cd ../terraform

# 2. Download the Terraform providers (one time)
terraform init

# 3. Preview what will be created — this changes nothing
terraform plan

# 4. Build it for real
terraform apply        # review the list, then type: yes
```

When it finishes, it prints your live URL:

```
api_url = "https://abc123.execute-api.eu-north-1.amazonaws.com"
```

### Test the live version

```bash
curl -X POST "https://<your-id>.execute-api.eu-north-1.amazonaws.com/calculate" \
  -H "Content-Type: application/json" \
  -d '{"operation":"add","a":60,"b":70}'
```

Same result as local (`130`), but now served from AWS and reachable anywhere.

### Watch the logs (cloud debugging)

There's no local debugger in the cloud, so stream the function's output:

```bash
aws logs tail /aws/lambda/simple-calculator-fn --follow --region eu-north-1
```

Fire a request in another terminal and watch your logs and any errors appear
live. This is the single most useful cloud-debugging habit.

---

## 5. Clean up

To remove everything and ensure nothing keeps running:

```bash
cd terraform
terraform destroy        # type: yes
```

Because the whole stack is code, you can rebuild it anytime with
`terraform apply`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `command not found: node` / `docker` / `terraform` | Tool not installed or not on PATH | Reinstall; restart the terminal |
| `Cannot find module '@aws-sdk/...'` locally | Libraries not installed | `cd lambda && npm install` |
| Local test hangs or errors connecting | DynamoDB Local isn't running | `docker compose up -d` |
| `ResourceNotFoundException` on a write | Table doesn't exist yet | Run `node local-test.js` once (it creates the table) |
| `scan` shows nothing locally | Missing `--endpoint-url` | Add `--endpoint-url http://localhost:8000` |
| Trailing `%` after a `curl` response | No trailing newline in the output | Ignore — it's harmless |
| `Unable to locate credentials` | AWS CLI not configured | Run `aws configure` |
| `is not authorized to perform: iam:PassRole` | IAM policy missing PassRole | Attach `IAMFullAccess` (or add the action) |
| `is not authorized to perform: <action>` | IAM policy missing that permission | Add the named action to your user's policy |
| Deployed Lambda returns a 500 / module error | `node_modules` wasn't in the upload | `npm install` in `lambda/`, then `terraform apply` again |
| Resources still exist after testing | Stack not torn down | `terraform destroy` |

---

## Difficulties faced (and how they were solved)

These are the real friction points encountered building this project — keeping
them documented helps the next person (and future-you).

**Making the same code run locally and on AWS.**
Solved with the `DYNAMODB_ENDPOINT` environment variable. When set, the code
talks to the local database; when absent (on AWS), it talks to real DynamoDB.
No code changes between environments.

**Environment variables must be set before the code loads.**
`index.js` builds its database client the moment it's imported, so
`local-test.js` and `local-server.js` set the environment variables *before*
the `require("./index.js")` line. Setting them later would be too late.

**The local table didn't exist.**
DynamoDB Local starts empty, so `local-test.js` creates the table before the
first write.

**The function could only be triggered by a script.**
Added `local-server.js` (a tiny Express web server) that converts an HTTP
request into the event shape AWS sends, so the API can be tested with `curl`.

**IAM permissions for `terraform apply`.**
The biggest hurdle. Terraform needs rights across DynamoDB, IAM, Lambda, and API
Gateway — and crucially the `iam:PassRole` action. See the
[permissions section](#permissions-your-iam-user-needs) above.

**Forgetting `npm install` before deploying.**
Terraform zips the `lambda/` folder including `node_modules`. If the libraries
aren't installed, the deployed function fails with a "Cannot find module" error.
Always `npm install` before `terraform apply`.

**Keeping secrets out of git.**
Terraform state files (`*.tfstate`) can contain sensitive data and are excluded
via `.gitignore`. AWS keys live in `~/.aws/`, never in the project. If a key
ever lands in a commit, rotate it immediately — git history keeps it otherwise.

---

## The one principle that ties it all together

Keep every AWS connection **configurable through environment variables**
(here, `DYNAMODB_ENDPOINT` and `TABLE_NAME`). That single habit is what lets the
identical code run against the local database or real AWS with no changes — the
foundation of a clean local-to-production workflow.
