import NodeRSA from "node-rsa";
import axios from "axios";
import crypto from "node:crypto";
import fs from "node:fs";

const privateKeyPem = process.env.PRIVATE_KEY_PEM;
const entity = process.env.ENTITY;
const presignedUrl = process.env.PRESIGNED_URL;
const encryptedAesKey = process.env.ENCRYPTED_AES_KEY;
const encodedAesIv = process.env.ENCODED_AES_IV;
const outputDir = process.env.OUTPUT_DIR;

async function decryptPayload() {
  if (!privateKeyPem || !entity || !presignedUrl || !encryptedAesKey || !encodedAesIv || !outputDir) {
    console.error("Error: Missing environment variables.");
    process.exit(1);
  }

  try {

    const privateKey = new NodeRSA(privateKeyPem);
    privateKey.setOptions({ encryptionScheme: "pkcs1", environment: "browser" });
    const aesKey = privateKey.decrypt(encryptedAesKey);
    const aesIv = Buffer.from(encodedAesIv, "base64");

    const encryptedData = await axios
      .get(presignedUrl, { responseType: "arraybuffer", timeout: 10000 })
      .then((r) => Buffer.from(r.data, "binary"));

    const aesDecryptor = crypto.createDecipheriv("aes-128-cbc", aesKey, aesIv);
    const decryptedChunks = [];
    decryptedChunks.push(aesDecryptor.update(encryptedData));
    decryptedChunks.push(aesDecryptor.final());

    const decryptedDataBuffer = Buffer.concat(decryptedChunks);
    const filePath = `${outputDir}/${entity}.csv`;

    fs.writeFile(filePath, decryptedDataBuffer, (e) => {
      if (e) {
        console.log(e);
        process.exit(1);
      }
    });
    console.log(`Written output CSV to ${filePath}`);

  } catch (e) {
    console.error(`Decryption Failed: ${e.message || e.toString()}`);
    process.exit(1);
  }
}

decryptPayload();