# Async::GRPC

Asynchronous gRPC client and server implementation built on top of `protocol-grpc` and `async-http`.

[![Development Status](https://github.com/socketry/async-grpc/workflows/Test/badge.svg)](https://github.com/socketry/async-grpc/actions?workflow=Test)

## Features

`async-grpc` provides asynchronous networking and concurrency for gRPC:

  - **Asynchronous client** - Wraps `Async::HTTP::Client` to provide gRPC-specific call methods with automatic message framing and status handling.
  - **Method-based stubs** - Create type-safe stubs from `Protocol::GRPC::Interface` definitions. Accepts both PascalCase and snake\_case method names for convenience.
  - **Server middleware** - `DispatcherMiddleware` routes requests to registered services based on path.
  - **All RPC patterns** - Supports unary, server streaming, client streaming, and bidirectional streaming RPCs.
  - **Interface-based services** - Define services using `Protocol::GRPC::Interface` with automatic PascalCase to snake\_case method name conversion for Ruby implementations.
  - **HTTP/2 transport** - Built on `async-http` with automatic HTTP/2 multiplexing and connection pooling.

## Usage

Please see the [project documentation](https://socketry.github.io/async-grpc/) for more details.

  - [Getting Started](https://socketry.github.io/async-grpc/guides/getting-started/index) - This guide explains how to get started with `Async::GRPC` for building gRPC clients and servers.

## Releases

Please see the [project releases](https://socketry.github.io/async-grpc/releases/index) for all releases.

### Unreleased

  - Tidy up request and response body handling.

### v0.1.0

  - Initial hack.

## See Also

  - [protocol-grpc](https://github.com/socketry/protocol-grpc) — Protocol abstractions for gRPC that this gem builds upon.
  - [async-http](https://github.com/socketry/async-http) — Asynchronous HTTP client and server with HTTP/2 support.
  - [protocol-http](https://github.com/socketry/protocol-http) — HTTP protocol abstractions.

## Contributing

We welcome contributions to this project.

1.  Fork it.
2.  Create your feature branch (`git checkout -b my-new-feature`).
3.  Commit your changes (`git commit -am 'Add some feature'`).
4.  Push to the branch (`git push origin my-new-feature`).
5.  Create new Pull Request.

### Developer Certificate of Origin

In order to protect users of this project, we require all contributors to comply with the [Developer Certificate of Origin](https://developercertificate.org/). This ensures that all contributions are properly licensed and attributed.

### Community Guidelines

This project is best served by a collaborative and respectful environment. Treat each other professionally, respect differing viewpoints, and engage constructively. Harassment, discrimination, or harmful behavior is not tolerated. Communicate clearly, listen actively, and support one another. If any issues arise, please inform the project maintainers.
