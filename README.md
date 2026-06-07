# AWS Lambda + DynamoDB + Terraform Calculator

A **serverless calculator API**. You send it two numbers and an operation; it
does the maths, saves the calculation to a database, and returns the answer —
all without a single server to manage.

This project is a complete, beginner-friendly example of how five modern cloud
technologies fit together. If you've never deployed anything to AWS before, you
can follow this start to finish.

> 📘 New here? Read **[SETUP.md](SETUP.md)** for a click-by-click guide that
> assumes no prior cloud experience.
> 🔍 Want to understand the code? Read **[CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md)**
> for a line-by-line explanation of every file.

---

## What it does

Send an HTTP request like this:

```json
{ "operation": "add", "a": 7, "b": 5 }
```

…and get back:

```json
{ "message": "Success", "input": { "operation": "add", "a": 7, "b": 5 }, "result": 12, "savedRecordId": "fc599d1b-..." }
```

Supported operations: `add`, `subtract`, `multiply`, `divide`.

---

## Architecture

```
   You / curl / Postman
          │  POST /calculate  { "operation":"add", "a":7, "b":5 }
          ▼
   ┌──────────────────┐
   │   API Gateway    │   a public HTTPS URL
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │  Lambda (Node.js)│   runs the calculator code
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │    DynamoDB      │   saves a record of every calculation
   └──────────────────┘
            │
            ▼  returns { "result": 12, ... }
```

| Piece | What it is | Role here |
|-------|-----------|-----------|
| **Node.js** | JavaScript runtime | The calculator code |
| **AWS Lambda** | Runs code without a server | Where the code executes |
| **DynamoDB** | A NoSQL database | Stores calculation history |
| **API Gateway** | A public HTTPS front door | Turns the Lambda into a web API |
| **Terraform** | Infrastructure as Code | Builds all the AWS pieces with one command |
| **Docker** | Containers | Runs a local database so you can test for free |

---

## Project structure

```
.
├── README.md              ← you are here
├── SETUP.md               ← step-by-step setup for beginners + troubleshooting
├── CODE_WALKTHROUGH.md    ← line-by-line explanation of every file
├── docker-compose.yml     ← local DynamoDB for offline testing
├── lambda/
│   ├── index.js           ← the calculator + database write (the core)
│   ├── package.json       ← lists the Node libraries needed
│   ├── package-lock.json  ← locks exact library versions
│   ├── local-test.js      ← runs the handler once, locally
│   └── local-server.js    ← a local API so you can curl it
└── terraform/
    ├── main.tf            ← all the AWS infrastructure
    ├── variables.tf       ← settings (region, project name)
    └── outputs.tf         ← prints your API URL after deploy
```

---

## Prerequisites

Install these once. See **[SETUP.md](SETUP.md)** for download links and
verification commands.

- **Node.js** 20 or newer
- **Docker** (for local testing)
- **Terraform** 1.5 or newer
- **AWS CLI** v2, configured with your AWS account
- **Git**

---

## Quick start — run it locally (free, no AWS needed)

```bash
# 1. Start a local database in Docker
docker compose up -d

# 2. Install the Node libraries
cd lambda
npm install

# 3. Create the table and run one calculation
node local-test.js
#    → Status: 200 Body: {... "result":12 ...}

# 4. Start a local API and call it like the real thing
npm install express
node local-server.js          # leave running

# in a second terminal:
curl -X POST http://localhost:3000/calculate \
  -H "Content-Type: application/json" \
  -d '{"operation":"add","a":7,"b":5}'
```

If you get `"result":12`, your whole local setup works. 🎉

---

## Deploy to AWS

```bash
# Make sure dependencies are installed so Terraform can package them
cd lambda && npm install && cd ../terraform

terraform init      # download providers (one time)
terraform plan      # preview what will be created — changes nothing
terraform apply     # create it all (type "yes"); prints your api_url
```

Then call your live URL:

```bash
curl -X POST "https://<your-id>.execute-api.eu-north-1.amazonaws.com/calculate" \
  -H "Content-Type: application/json" \
  -d '{"operation":"multiply","a":6,"b":7}'
```

> ⚠️ Your AWS IAM user needs permission to create these resources. See the
> **IAM permissions** section in [SETUP.md](SETUP.md).

---

## Clean up (avoid charges)

When you're done experimenting:

```bash
cd terraform
terraform destroy   # type "yes"
```

This removes the Lambda, API Gateway, IAM role, and table. Costs while idle are
effectively zero (free tier + pay-per-use), but tearing down is good practice.

---

## How it works (in one paragraph)

Your code reads its configuration — the database location and table name — from
**environment variables** rather than hard-coding them. Locally, you set
`DYNAMODB_ENDPOINT` to point at Docker; on AWS, that variable is absent, so the
SDK connects to real DynamoDB instead. This is why the *exact same* `index.js`
runs in both places with no changes. Terraform supplies the AWS configuration
and builds every resource; Docker lets you rehearse locally for free first.

For the full details, see **[CODE_WALKTHROUGH.md](CODE_WALKTHROUGH.md)**.

---

## Tech

Node.js · AWS Lambda · DynamoDB · API Gateway · Terraform · Docker

## License

MIT — free to use, learn from, and build on.
