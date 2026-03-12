const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const s3 = new S3Client({});

exports.handler = async (event) => {
  const body = JSON.parse(event.body);
  const imageData = Buffer.from(body.image, "base64");
  const key = `photos/${Date.now()}-${body.filename}`;

  await s3.send(new PutObjectCommand({
    Bucket: process.env.PHOTOS_BUCKET,
    Key: key,
    Body: imageData,
    ContentType: body.contentType || "image/jpeg",
  }));

  return {
    statusCode: 200,
    headers: { "Access-Control-Allow-Origin": "*" },
    body: JSON.stringify({ message: "Upload successful", key }),
  };
};