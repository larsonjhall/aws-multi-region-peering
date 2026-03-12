const { DynamoDBClient, ScanCommand } = require("@aws-sdk/client-dynamodb");
const dynamo = new DynamoDBClient({});

exports.handler = async () => {
  const result = await dynamo.send(new ScanCommand({
    TableName: process.env.DYNAMODB_TABLE,
  }));

  const items = result.Items.map(item => ({
    imageKey:  item.imageKey.S,
    labels:    JSON.parse(item.labels.S),
    timestamp: item.timestamp.S,
  }));

  items.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

  return {
    statusCode: 200,
    headers: { "Access-Control-Allow-Origin": "*" },
    body: JSON.stringify(items),
  };
};