const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, PutCommand } = require("@aws-sdk/lib-dynamodb");
const { randomUUID } = require("crypto");

// Same code runs locally and on AWS. Locally we point at DynamoDB Local.
const clientConfig = process.env.DYNAMODB_ENDPOINT
  ? { endpoint: process.env.DYNAMODB_ENDPOINT, region: "local",
      credentials: { accessKeyId: "local", secretAccessKey: "local" } }
  : {};
const docClient = DynamoDBDocumentClient.from(new DynamoDBClient(clientConfig));
const TABLE_NAME = process.env.TABLE_NAME;

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

function response(statusCode, body) {
  return { statusCode, headers: { "Content-Type": "application/json" },
           body: JSON.stringify(body) };
}

exports.handler = async (event) => {
  try {
    const body = event.body ? JSON.parse(event.body) : {};
    const { operation, a, b } = body;
    if (typeof a !== "number" || typeof b !== "number")
      return response(400, { message: "'a' and 'b' must be numbers." });
    if (!operation)
      return response(400, { message: "'operation' is required." });

    const result = calculate(operation, a, b);
    const item = { id: randomUUID(), operation, a, b, result,
                   createdAt: new Date().toISOString() };
    await docClient.send(new PutCommand({ TableName: TABLE_NAME, Item: item }));

    return response(200, { message: "Success", input: { operation, a, b },
                           result, savedRecordId: item.id });
  } catch (err) {
    console.error(err);
    return response(400, { message: err.message });
  }
};
