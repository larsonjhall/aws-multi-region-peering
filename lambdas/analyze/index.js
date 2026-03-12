const { RekognitionClient, DetectLabelsCommand } = require("@aws-sdk/client-rekognition");
const { DynamoDBClient, PutItemCommand } = require("@aws-sdk/client-dynamodb");

const rekognition = new RekognitionClient({});
const dynamo = new DynamoDBClient({});

exports.handler = async (event) => {
  for (const record of event.Records) {
    const bucket = record.s3.bucket.name;
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

    const labelResult = await rekognition.send(new DetectLabelsCommand({
      Image: { S3Object: { Bucket: bucket, Name: key } },
      MaxLabels: 10,
      MinConfidence: 70,
    }));

    const labels = labelResult.Labels.map(l => ({
      name: l.Name,
      confidence: Math.round(l.Confidence),
    }));

    await dynamo.send(new PutItemCommand({
      TableName: process.env.DYNAMODB_TABLE,
      Item: {
        imageKey:  { S: key },
        labels:    { S: JSON.stringify(labels) },
        timestamp: { S: new Date().toISOString() },
        bucket:    { S: bucket },
      },
    }));
  }
};