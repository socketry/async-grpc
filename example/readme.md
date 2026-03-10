# async-grpc Sample: Falcon / HTTP/2 / gRPC Server

This sample demonstrates a gRPC server using Falcon with HTTP/2, implementing all 4 gRPC call types:

1. **Unary** (`SayHello`) - single request, single response
2. **Server streaming** (`StreamNumbers`) - single request, stream of responses
3. **Client streaming** (`CollectNames`) - stream of requests, single response
4. **Bidirectional streaming** (`Chat`) - stream of requests, stream of responses

## Setup

```bash
bundle install
bake build   # or: ./regenerate_proto.sh
```

## Running the Server

```bash
bundle exec falcon host falcon.rb
```

The server listens on `http://localhost:50051` with HTTP/2.

## Running the Client

In a separate terminal:

```bash
bundle exec ruby client.rb
```

## Using grpcurl

[grpcurl](https://github.com/fullstorydev/grpcurl) is a command-line tool for making gRPC requests. Install it via Homebrew (`brew install grpcurl`) or from the [releases](https://github.com/fullstorydev/grpcurl/releases).

Since the server does not enable gRPC reflection, pass the proto file with `-proto`:

```bash
# Unary
grpcurl -plaintext -proto my_service.proto -d '{"name":"World"}' localhost:50051 my_service.Greeter/SayHello

# Server streaming
grpcurl -plaintext -proto my_service.proto -d '{"name":"Stream"}' localhost:50051 my_service.Greeter/StreamNumbers

# Client streaming (-d '@' reads from stdin; one JSON object per line)
printf '{"name":"Alice"}\n{"name":"Bob"}\n{"name":"Carol"}\n' | grpcurl -plaintext -proto my_service.proto -d '@' localhost:50051 my_service.Greeter/CollectNames

# Bidirectional streaming (-d '@' reads from stdin; waits for interactive input)
grpcurl -plaintext -proto my_service.proto -d '@' localhost:50051 my_service.Greeter/Chat
# Type one JSON object per line, then Ctrl-D when done. Or pipe: printf '{"name":"hi"}\n{"name":"there"}\n' | grpcurl ...
```

## Files

- `my_service.proto` - Protocol buffer definition with all 4 RPC types
- `greeter_interface.rb` - Protocol::GRPC::Interface definition
- `greeter_service.rb` - Async::GRPC::Service implementation
- `falcon.rb` - Falcon server configuration (HTTP/2)
- `client.rb` - Example client exercising all 4 call types
