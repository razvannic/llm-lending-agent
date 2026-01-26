package com.yourorg.agent;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

public class AgentGatewayHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    private final DynamoDbClient ddb = DynamoDbClient.create();
    private final String tableName = System.getenv("DDB_TABLE_NAME");
    private final String env = System.getenv().getOrDefault("ENV", "dev");

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        context.getLogger().log("AgentGatewayHandler invoked. tableName=" + tableName + ", env=" + env + "\n");

        try {
            if (tableName == null || tableName.isBlank()) {
                return json(500, "{\"ok\":false,\"error\":\"DDB_TABLE_NAME is missing\"}");
            }

            String sessionId = UUID.randomUUID().toString();

            Map<String, AttributeValue> item = new HashMap<>();
            item.put("PK", AttributeValue.fromS("SESSION#" + sessionId));
            item.put("SK", AttributeValue.fromS("STATE"));
            item.put("env", AttributeValue.fromS(env));
            item.put("createdAt", AttributeValue.fromS(Instant.now().toString()));
            item.put("ttl", AttributeValue.fromN(Long.toString(Instant.now().plusSeconds(14 * 24 * 3600).getEpochSecond())));

            ddb.putItem(PutItemRequest.builder()
                    .tableName(tableName)
                    .item(item)
                    .build());

            String body = """
              {"ok":true,"sessionId":"%s","message":"walking skeleton works"}
              """.formatted(sessionId).trim();

            return json(200, body);

        } catch (Exception e) {
            context.getLogger().log("ERROR: " + e + "\n");
            for (StackTraceElement el : e.getStackTrace()) {
                context.getLogger().log("  at " + el + "\n");
            }
            return json(500, "{\"ok\":false,\"error\":\"" + escape(e.toString()) + "\"}");
        }
    }

    private static APIGatewayV2HTTPResponse json(int code, String body) {
        return APIGatewayV2HTTPResponse.builder()
                .withStatusCode(code)
                .withHeaders(Map.of(
                        "content-type", "application/json",
                        "access-control-allow-origin", "*",
                        "access-control-allow-headers", "content-type,authorization",
                        "access-control-allow-methods", "POST,OPTIONS"
                ))
                .withBody(body)
                .build();
    }

    private static String escape(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
