# DB-Backend Transport Specification

## 1. Introduction

This document specifies the transport mechanism used by the `db-backend` component for communication with external clients, primarily debuggers or development environments. The transport layer facilitates the exchange of messages conforming to the Debug Adapter Protocol (DAP).

## 2. Protocol Overview

The `db-backend` utilizes the Debug Adapter Protocol (DAP) as its primary communication protocol. DAP defines a generic protocol for debuggers and development environments to communicate with debug adapters. This specification focuses on how these DAP messages are transmitted over a communication channel.

## 3. Message Structure

DAP messages are exchanged using a simple, length-prefixed JSON format. Each message consists of two parts:

1.  **Header**: A set of HTTP-like headers, terminated by a `\r\n\r\n` sequence. The most crucial header is `Content-Length`, which indicates the size of the following JSON payload in bytes.
    ```/dev/null/example.txt#L1-2
    Content-Length: 123
    Content-Type: application/json
    ```
    The `Content-Type` header is optional but recommended. If present, its value must be `application/json`.

2.  **Content**: The actual DAP message, which is a JSON object encoded in UTF-8. The size of this content must exactly match the `Content-Length` specified in the header.

Example of a complete message:
```/dev/null/example.txt#L1-5
Content-Length: 72
Content-Type: application/json

{"seq":1, "type":"request", "command":"initialize", "arguments":{"adapterID":"db"}}
```

## 4. Transport Layer

The `db-backend` primarily uses **Standard I/O (stdin/stdout)** for its transport layer.

*   **Input (stdin)**: The `db-backend` reads incoming DAP messages from its standard input stream.
*   **Output (stdout)**: The `db-backend` writes outgoing DAP messages to its standard output stream.

Each message (header + content) is transmitted as a contiguous block of bytes. There should be no additional delimiters or framing between messages beyond the `\r\n\r\n` separator between the header and the content.

## 5. Error Handling

### 5.1. Malformed Messages

If the `db-backend` receives a message that does not conform to the specified header and content format (e.g., missing `Content-Length`, invalid `Content-Length`, or non-JSON content), it should:

*   Attempt to log the error internally (if a logging mechanism is available).
*   Discard the malformed message.
*   Continue processing subsequent messages, if possible.
*   It should **not** send an error response over the DAP channel for transport-layer parsing errors, as the message might be too corrupted to respond to meaningfully.

### 5.2. Protocol Errors (DAP Level)

Errors within the DAP message content (e.g., unknown command, invalid arguments for a command) should be handled according to the DAP specification, typically by sending a `response` message with the `success` field set to `false` and an appropriate `message` and `body.error` field.

### 5.3. Transport Failures

If the standard I/O streams are closed unexpectedly or encounter read/write errors, the `db-backend` should terminate gracefully, logging the nature of the transport failure.