# Releases

## Unreleased

  - Renamed `DispatcherMiddleware` to `Dispatcher` for cleaner API.
  - Simplified `Dispatcher#register` API to `register(service, name: service.service_name)`, eliminating redundant service name specification.

## v0.2.0

  - Added `Async::GRPC::RemoteError` class to encapsulate remote error details including message and backtrace extracted from response headers.
  - Client-side error handling now extracts backtraces from response metadata and sets them on `RemoteError`, which is chained as the `cause` of `Protocol::GRPC::Error` for better debugging.
  - Updated to use `Protocol::GRPC::Metadata.add_status!` instead of deprecated `add_status_trailer!` method.
  - Tidy up request and response body handling.

## v0.1.0

  - Initial hack.
