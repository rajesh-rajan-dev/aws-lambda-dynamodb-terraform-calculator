// A tiny local stand-in for API Gateway. It turns an HTTP request into the
// same "event" object your Lambda gets on AWS, then calls your handler.
const express = require("express");

process.env.DYNAMODB_ENDPOINT = "http://localhost:8000";
process.env.TABLE_NAME = "simple-calculator-history";
const { handler } = require("./index.js");

const app = express();
app.use(express.text({ type: "*/*" })); // capture the raw body as a string

app.post("/calculate", async (req, res) => {
  const event = { body: req.body };      // mimic what API Gateway sends
  const result = await handler(event);   // call your real handler
  res.status(result.statusCode).type("json").send(result.body);
});

app.listen(3000, () => console.log("Local API running on http://localhost:3000"));
