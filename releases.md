# Releases

## v0.6.0

  - Ensure `grpc-status` (and related metadata) is sent as a trailer, if data frames are written.

## v0.5.1

  - Better error logging on timeout.

## v0.5.0

  - Fix handling of timeouts/deadlines.

## v0.4.0

  - Fix handling of trailers.

## v0.3.0

  - **Breaking**: Renamed `DispatcherMiddleware` to `Dispatcher` for cleaner API.
  - **Breaking**: Simplified `Dispatcher#register` API to `register(service, name: service.service_name)`, eliminating redundant service name specification.

## v0.2.0

  - Added `Async::GRPC::RemoteError` class to encapsulate remote error details including message and backtrace extracted from response headers.
  - Client-side error handling now extracts backtraces from response metadata and sets them on `RemoteError`, which is chained as the `cause` of `Protocol::GRPC::Error` for better debugging.
  - Updated to use `Protocol::GRPC::Metadata.add_status!` instead of deprecated `add_status_trailer!` method.
  - Tidy up request and response body handling.

## v0.1.0

  - Initial hack.
