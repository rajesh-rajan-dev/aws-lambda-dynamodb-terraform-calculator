# Code Walkthrough

A line-by-line explanation of every file in this project. If you've read the
[README](README.md) and want to understand *how* the code actually works — not
just how to run it — this is the file for you.

Files covered:

1. [`lambda/index.js`](#1-lambdaindexjs--the-core) — the calculator + database write
2. [`lambda/local-test.js`](#2-lambdalocal-testjs--the-local-test-runner)
3. [`lambda/local-server.js`](#3-lambdalocal-serverjs--the-local-api)
4. [`terraform/main.tf`](#4-terraformmaintf--the-infrastructure)
5. [`terraform/variables.tf`](#5-terraformvariablestf--the-settings)
6. [`terraform/outputs.tf`](#6-terraformoutputstf--the-results)
7. [`docker-compose.yml`](#7-docker-composeyml--the-local-database)

---

## 1. `lambda/index.js` — the core

This is the function AWS runs on every request. It does three things: validate
the input, do the maths, and save the result.

### Imports

```javascript
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");
const { randomUUID } = require("crypto");
```

- `DynamoDBClient` — the low-level client that talks to DynamoDB.
- `DynamoDBDocumentClient` — a friendly wrapper so we can use plain JavaScript
  objects (`{ id: "abc" }`) instead of DynamoDB's verbose typed format
  (`{ id: { S: "abc" } }`).
- `PutCommand` — the command that inserts one item into a table.
- `randomUUID` — built into Node (no install needed); generates a unique ID
  like `fc599d1b-0341-...` for each saved calculation.

### Building the database client (the clever part)

```javascript
const clientConfig = process.env.DYNAMODB_ENDPOINT
  ? { endpoint: process.env.DYNAMODB_ENDPOINT, region: "local",
      credentials: { accessKeyId: "local", secretAccessKey: "local" } }
  : {};
const docClient = DynamoDBDocumentClient.from(new DynamoDBClient(clientConfig));
const TABLE_NAME = process.env.TABLE_NAME;
```

This is what makes the same file work locally and on AWS:

- `process.env.DYNAMODB_ENDPOINT` reads an environment variable.
- The `? :` is a **ternary** (a compact if/else). If `DYNAMODB_ENDPOINT` is
  **set** (running locally), build a config pointing at the local database with
  dummy credentials. If it's **not set** (running on AWS), use `{}` — an empty
  config — and the SDK figures out the real endpoint and credentials itself.
- This client is created **once at the top of the file**, not inside the
  handler. AWS reuses the same function instance across many requests
  ("warm starts"), so building it once saves time.
- `TABLE_NAME` also comes from an environment variable, so the table name is
  never hard-coded — Terraform supplies it on AWS, the test scripts supply it
  locally.

### The calculator

```javascript
function calculate(operation, a, b) {
  switch (operation) {
    case "add":      return a + b;
    case "subtract": return a - b;
    case "multiply": return a * b;
    case "divide":
      if (b === 0) throw new Error("Cannot divide by zero");
      return a / b;
    default: throw new Error(`Unknown operation: "${operation}"`);
  }
}
```

A `switch` picks the branch matching `operation`. Each `case` returns the
result. Two guards: dividing by zero throws an error, and any unrecognised
operation hits `default` and throws. Throwing here is deliberate — the handler
catches these and turns them into a clean error response.

### The response helper

```javascript
function response(statusCode, body) {
  return { statusCode, headers: { "Content-Type": "application/json" },
           body: JSON.stringify(body) };
}
```

API Gateway expects a very specific response shape: a status code, headers, and
a body that is a **string**. This helper builds that shape so we don't repeat it.
`JSON.stringify` turns our JavaScript object into a JSON string.

### The handler (the entry point)

```javascript
exports.handler = async (event) => {
```

`exports.handler` is what AWS calls. `event` is the incoming request. `async`
means it can use `await` for the database call.

```javascript
  try {
    const body = event.body ? JSON.parse(event.body) : {};
    const { operation, a, b } = body;
```

API Gateway delivers the request body as a **string**, so `JSON.parse` turns it
back into an object. The `? :` guards against a missing body. The next line is
**destructuring** — it pulls `operation`, `a`, and `b` out of the object in one
step.

```javascript
    if (typeof a !== "number" || typeof b !== "number")
      return response(400, { message: "'a' and 'b' must be numbers." });
    if (!operation)
      return response(400, { message: "'operation' is required." });
```

Validation. `typeof` checks the type — this rejects `"7"` (a string) where `7`
(a number) is required. `400` is the HTTP code for "bad request." Returning here
stops the function before it does anything risky.

```javascript
    const result = calculate(operation, a, b);
    const item = { id: randomUUID(), operation, a, b, result,
                   createdAt: new Date().toISOString() };
    await docClient.send(new PutCommand({ TableName: TABLE_NAME, Item: item }));
```

Do the maths, then build the record to save: a unique `id`, the inputs, the
`result`, and a timestamp (`toISOString()` gives a standard date string).
`await docClient.send(new PutCommand(...))` writes that record to DynamoDB and
waits for it to finish.

```javascript
    return response(200, { message: "Success", input: { operation, a, b },
                           result, savedRecordId: item.id });
  } catch (err) {
    console.error(err);
    return response(400, { message: err.message });
  }
};
```

On success, return `200` with the result and the saved record's ID. If anything
threw an error along the way (divide by zero, unknown operation, bad JSON), the
`catch` logs it (visible in CloudWatch on AWS) and returns a clean `400` with
the error message — the function never crashes ungracefully.

---

## 2. `lambda/local-test.js` — the local test runner

Runs the handler once on your machine against the local database.

```javascript
const { DynamoDBClient, CreateTableCommand, ListTablesCommand }
  = require("@aws-sdk/client-dynamodb");

const ENDPOINT = "http://localhost:8000";
const TABLE_NAME = "simple-calculator-history";
process.env.DYNAMODB_ENDPOINT = ENDPOINT;
process.env.TABLE_NAME = TABLE_NAME;
const { handler } = require("./index.js");
```

It imports extra commands to *create* and *list* tables. It then sets the two
environment variables — and this order is critical: they're set **before**
`require("./index.js")`, because `index.js` builds its database client the
instant it's imported. Set them after, and the client would already exist with
the wrong configuration.

```javascript
const client = new DynamoDBClient({ endpoint: ENDPOINT, region: "local",
  credentials: { accessKeyId: "local", secretAccessKey: "local" } });
```

A separate admin client used only to create the table.

```javascript
async function run() {
  const { TableNames } = await client.send(new ListTablesCommand({}));
  if (!TableNames.includes(TABLE_NAME)) {
    await client.send(new CreateTableCommand({
      TableName: TABLE_NAME,
      KeySchema: [{ AttributeName: "id", KeyType: "HASH" }],
      AttributeDefinitions: [{ AttributeName: "id", AttributeType: "S" }],
      BillingMode: "PAY_PER_REQUEST",
    }));
    console.log("Table created.");
  }
```

It lists existing tables; if ours isn't there, it creates it. `KeySchema` with
`KeyType: "HASH"` makes `id` the primary key; `AttributeType: "S"` means the id
is a String. (DynamoDB Local starts empty, which is why this step exists.)

```javascript
  const event = { body: JSON.stringify({ operation: "add", a: 7, b: 5 }) };
  const result = await handler(event);
  console.log("Status:", result.statusCode, "Body:", result.body);
}
run().catch(console.error);
```

It builds a fake `event` exactly like the one API Gateway would send (note
`body` is a JSON **string**), calls the real handler, and prints the result.
`run().catch(...)` runs everything and prints any error instead of crashing.

---

## 3. `lambda/local-server.js` — the local API

A tiny web server so you can `curl` the calculator locally, exactly as you would
the deployed version.

```javascript
const express = require("express");

process.env.DYNAMODB_ENDPOINT = "http://localhost:8000";
process.env.TABLE_NAME = "simple-calculator-history";
const { handler } = require("./index.js");
```

`express` is a popular library for building web servers in Node. Again, the
environment variables are set **before** importing the handler.

```javascript
const app = express();
app.use(express.text({ type: "*/*" }));
```

Creates the server. `express.text({ type: "*/*" })` tells Express to hand us the
raw request body as a plain string — which matches what API Gateway gives the
handler, so the handler doesn't need to change.

```javascript
app.post("/calculate", async (req, res) => {
  const event = { body: req.body };
  const result = await handler(event);
  res.status(result.statusCode).type("json").send(result.body);
});
```

When a `POST` arrives at `/calculate`, it wraps the body into the same `event`
shape AWS uses, calls the **real handler**, and sends the handler's response
back over HTTP — translating `statusCode` and `body` into a real HTTP response.
This is exactly what API Gateway does on AWS; here we do it in a few lines.

```javascript
app.listen(3000, () => console.log("Local API running on http://localhost:3000"));
```

Starts the server on port 3000.

---

## 4. `terraform/main.tf` — the infrastructure

This file describes every AWS resource. Terraform reads it and creates them in
the right order automatically (it works out the order from how resources
reference each other).

### Providers and packaging

```hcl
terraform {
  required_providers {
    aws     = { source = "hashicorp/aws",     version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.aws_region
}
```

Declares which plugins Terraform needs (`aws` to make AWS resources, `archive`
to zip files) and tells the AWS provider which region to use, pulled from a
variable.

```hcl
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda.zip"
}
```

Lambda is deployed as a `.zip`. This automatically zips the `lambda/` folder
(code **and** `node_modules`) every time you apply. `path.module` means "the
folder this `.tf` file is in," and `../lambda` steps up and over to the code.

### DynamoDB table

```hcl
resource "aws_dynamodb_table" "history" {
  name         = "${var.project_name}-history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}
```

Creates the table. `PAY_PER_REQUEST` means you pay per use with nothing to
pre-size — ideal for low traffic. `hash_key = "id"` sets the primary key, and
the `attribute` block declares `id` as a String. (You only declare attributes
used as keys in DynamoDB.)

### IAM role — the Lambda's identity

```hcl
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}
```

A role is a bundle of permissions the Lambda runs with. This **trust policy**
says "the Lambda service is allowed to assume this role." `jsonencode` turns the
Terraform object into the JSON format AWS expects.

```hcl
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
```

Attaches an AWS-provided policy that lets the Lambda write logs to CloudWatch —
essential for debugging.

```hcl
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${var.project_name}-dynamodb-access"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
      Resource = aws_dynamodb_table.history.arn
    }]
  })
}
```

A custom policy letting the Lambda read and write — but **only our table**
(`Resource` points at this table's ARN). This is "least privilege": grant the
minimum needed, nothing more.

### The Lambda function

```hcl
resource "aws_lambda_function" "calculator" {
  function_name    = "${var.project_name}-fn"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  timeout          = 10
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.history.name
    }
  }
}
```

Creates the function. It references the zip and the role from above.
`source_code_hash` is a fingerprint of the zip — when your code changes, the
hash changes, so Terraform knows to redeploy. `handler = "index.handler"` means
"the `handler` function exported from `index.js`." Note the `environment` block
passes `TABLE_NAME` but **not** `DYNAMODB_ENDPOINT` — that absence is exactly
why the code uses real DynamoDB on AWS.

### API Gateway — the public front door

```hcl
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.calculator.invoke_arn
  payload_format_version = "2.0"
}
```

Creates the HTTP API and connects it to the Lambda. `AWS_PROXY` means "pass the
whole request straight through to the function untouched" — which is why the
handler receives the raw `event`.

```hcl
resource "aws_apigatewayv2_route" "calculate_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /calculate"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}
```

The route says a `POST` to `/calculate` goes to our Lambda. The stage is a
deployed instance of the API; `$default` with `auto_deploy` means changes go
live automatically.

```hcl
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.calculator.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}
```

The crucial last piece: without this, API Gateway is **not allowed** to call
your Lambda. This grants exactly that permission.

---

## 5. `terraform/variables.tf` — the settings

```hcl
variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "project_name" {
  type    = string
  default = "simple-calculator"
}
```

Adjustable settings, referenced elsewhere as `var.aws_region` and
`var.project_name`. Change the region here, or override on the command line with
`terraform apply -var="aws_region=eu-west-1"`. `project_name` is the prefix on
every resource name, so they're easy to find and delete together.

---

## 6. `terraform/outputs.tf` — the results

```hcl
output "api_url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}
```

After `terraform apply`, this prints your live API's base URL so you know where
to send requests. Reprint it anytime with `terraform output`.

---

## 7. `docker-compose.yml` — the local database

```yaml
services:
  dynamodb-local:
    image: amazon/dynamodb-local:latest
    container_name: calculator-dynamodb
    ports:
      - "8000:8000"
    command: "-jar DynamoDBLocal.jar -inMemory -sharedDb"
```

Defines one container running AWS's official **DynamoDB Local** image.
`"8000:8000"` maps the container's port 8000 to your machine's port 8000, so the
code can reach it at `http://localhost:8000`. `-inMemory` keeps data in memory
(it resets when the container stops), and `-sharedDb` makes all connections use
one shared database. Start it with `docker compose up -d`, stop it with
`docker compose down`.

---

## The big idea, one more time

Every connection to AWS is configured through **environment variables**, never
hard-coded. `DYNAMODB_ENDPOINT` and `TABLE_NAME` are set by the local scripts
when running locally, and by Terraform when running on AWS. That's the single
design choice that lets the identical `index.js` run in both places — and it's
the foundation of professional cloud development.
