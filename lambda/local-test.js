const { DynamoDBClient, CreateTableCommand, ListTablesCommand }
  = require("@aws-sdk/client-dynamodb");

const ENDPOINT = "http://localhost:8000";
const TABLE_NAME = "simple-calculator-history";
process.env.DYNAMODB_ENDPOINT = ENDPOINT;
process.env.TABLE_NAME = TABLE_NAME;
const { handler } = require("./index.js");

const client = new DynamoDBClient({ endpoint: ENDPOINT, region: "local",
  credentials: { accessKeyId: "local", secretAccessKey: "local" } });

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
  const event = { body: JSON.stringify({ operation: "multiply", a: 1000, b: 500 }) };
  const result = await handler(event);
  console.log("Status:", result.statusCode, "Body:", result.body);
}
run().catch(console.error);
