# Async::GRPC Design

Client and server implementation for gRPC using Async, built on top of `protocol-grpc`.

## Overview

`async-grpc` provides the networking and concurrency layer for gRPC:
- **`Async::GRPC::Client`** - wraps `Async::HTTP::Client` for making gRPC calls
- **`Async::GRPC::Server`** - `Protocol::HTTP::Middleware` for handling gRPC requests
- Built on top of `protocol-grpc` for protocol abstractions
- Uses `async-http` for HTTP/2 transport

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        async-grpc                            │
│  (Client/Server implementations with Async concurrency)      │
├─────────────────────────────────────────────────────────────┤
│                      protocol-grpc                           │
│  (Protocol abstractions: framing, headers, status codes)     │
├─────────────────────────────────────────────────────────────┤
│                      protocol-http                           │
│  (HTTP abstractions: Request, Response, Headers, Body)       │
├─────────────────────────────────────────────────────────────┤
│                 async-http / protocol-http2                  │
│           (HTTP/2 transport and connection management)       │
└─────────────────────────────────────────────────────────────┘
```

## Design Pattern: Body Wrapping

Following the pattern from `async-rest`, we wrap response bodies with rich parsing using `Protocol::HTTP::Body::Wrapper`:

```ruby
# In protocol-grpc:
class Protocol::GRPC::Body::Readable < Protocol::HTTP::Body::Wrapper
	# gRPC bodies are ALWAYS message-framed, so this is the standard readable body
	def initialize(body, message_class: nil, encoding: nil)
		super(body)
		@message_class = message_class
		@encoding = encoding
		@buffer = String.new.force_encoding(Encoding::BINARY)
	end
	
	# Override read to return decoded messages instead of raw chunks
	def read
		# Read 5-byte prefix + message data
		# Decompress if needed
		# Decode with message_class if provided
	end
end

# In async-grpc, wrap responses transparently:
response = client.call(request)
response.body = Protocol::GRPC::Body::Readable.new(
	response.body,
	message_class: HelloReply,
	encoding: response.headers["grpc-encoding"]
)

# Now reading is natural - standard Protocol::HTTP::Body interface:
message = response.body.read  # Returns decoded HelloReply message!
```

This provides:
- **Transparent wrapping**: Response body is automatically enhanced
- **Lazy parsing**: Messages are decoded on demand
- **Streaming support**: Can iterate over messages naturally
- **Type safety**: Message class determines parsing

### Important: Homogeneous Message Types

**In gRPC, all messages in a stream are always the same type.** This is defined in the `.proto` file:

```protobuf
// All responses are HelloReply
rpc StreamNumbers(HelloRequest) returns (stream HelloReply);
```

This constraint simplifies the API significantly:
- You specify `message_class` **once** when wrapping the body
- All subsequent `read()` calls decode to that same class
- No need to check message types or handle polymorphism
- Standard `Protocol::HTTP::Body` interface (`read`, `each`) just works!

The four RPC patterns:
- **Unary**: 1 request of type A → 1 response of type B
- **Server streaming**: 1 request of type A → N responses of type B (all type B)
- **Client streaming**: N requests of type A (all type A) → 1 response of type B
- **Bidirectional**: N requests of type A (all type A) ↔ M responses of type B (all type B)

This is different from protocols like WebSockets where you might receive different message types in the same stream.

## Core Components Summary

`async-grpc` provides networking and concurrency layer for gRPC:

1. **Client** - `Async::GRPC::Client` (wraps `Async::HTTP::Client`)
   - Four RPC methods: `unary`, `server_streaming`, `client_streaming`, `bidirectional_streaming`
   - Binary variants for channel adapter: `*_binary` methods
   - Automatic body wrapping with `Protocol::GRPC::Body::Readable`

2. **Server** - Use `Protocol::GRPC::Middleware` with `Async::HTTP::Server`
   - No separate Async::GRPC::Server needed!
   - Protocol middleware handles dispatch
   - Async::HTTP::Server handles connections

3. **Server Context** - `Async::GRPC::ServerCall` (extends `Protocol::GRPC::Call`)
   - Access request metadata
   - Set response metadata/trailers
   - Deadline tracking
   - Cancellation support

4. **Interceptors** - `ClientInterceptor` and `ServerInterceptor`
   - Wrap RPC calls
   - Add cross-cutting concerns (logging, auth, metrics)

5. **Channel Adapter** - `Async::GRPC::ChannelAdapter`
   - Compatible with `GRPC::Core::Channel` interface
   - Enables drop-in replacement for standard gRPC
   - Google Cloud library integration

**Key Patterns:**
- Response bodies automatically wrapped with `Protocol::GRPC::Body::Readable`
- Standard `read`/`write`/`each` methods (not `read_message`/`write_message`)
- Compression handled via `encoding:` parameter

### Detailed Components

### 1. `Async::GRPC::Client`

Wraps `Async::HTTP::Client` to provide gRPC-specific call methods:

```ruby
module Async
	module GRPC
		class Client
			# @parameter endpoint [Async::HTTP::Endpoint] The server endpoint
			# @parameter authority [String] The server authority for requests
			def initialize(endpoint, authority: nil)
				@client = Async::HTTP::Client.new(endpoint, protocol: Async::HTTP::Protocol::HTTP2)
				@authority = authority || endpoint.authority
			end
			
			# Make a unary RPC call
			# @parameter service [String] Service name, e.g., "my_service.Greeter"
			# @parameter method [String] Method name, e.g., "SayHello"
			# @parameter request [Object] Protobuf request message
			# @parameter response_class [Class] Expected response message class
			# @parameter metadata [Hash] Custom metadata
			# @parameter timeout [Numeric] Deadline for the request
			# @returns [Object] Protobuf response message
			def unary(service, method, request, response_class: nil, metadata: {}, timeout: nil)
				# Build request body with single message
				body = Protocol::GRPC::Body::Writable.new
				body.write(request)
				body.close_write
				
				# Build HTTP request
				http_request = build_request(service, method, body, metadata: metadata, timeout: timeout)
				
				# Make the call
				http_response = @client.call(http_request)
				
				# Wrap response body with gRPC message parser
				# This follows async-rest pattern of wrapping body for rich parsing
				wrap_response_body(http_response, response_class)
				
				# Read single message - standard Protocol::HTTP::Body interface
				# The wrapper makes .read return decoded messages instead of raw chunks
				message = http_response.body.read
				
				# Check status
				check_status!(http_response)
				
				message
			end
			
			# Make a server streaming RPC call
			# @parameter service [String] Service name
			# @parameter method [String] Method name
			# @parameter request [Object] Protobuf request message
			# @parameter response_class [Class] Expected response message class
			# @yields {|response| ...} Each response message
			def server_streaming(service, method, request, response_class: nil, metadata: {}, timeout: nil, &block)
				return enum_for(:server_streaming, service, method, request, response_class: response_class, metadata: metadata, timeout: timeout) unless block_given?
				
				# Build request body with single message
				body = Protocol::GRPC::Body::Writable.new
				body.write(request)
				body.close_write
				
				# Build HTTP request
				http_request = build_request(service, method, body, metadata: metadata, timeout: timeout)
				
				# Make the call
				http_response = @client.call(http_request)
				
				# Wrap response body
				wrap_response_body(http_response, response_class)
				
				# Stream responses - standard Protocol::HTTP::Body#each
				# The wrapper makes each iterate decoded messages
				http_response.body.each do |message|
					yield message
				end
				
				# Check status
				check_status!(http_response)
			end
			
			# Make a client streaming RPC call
			# @parameter service [String] Service name
			# @parameter method [String] Method name
			# @parameter response_class [Class] Expected response message class
			# @yields {|stream| ...} Block that writes request messages to stream
			# @returns [Object] Protobuf response message
			def client_streaming(service, method, response_class: nil, metadata: {}, timeout: nil, &block)
				# Build request body
				body = Protocol::GRPC::Body::Writable.new
				
				# Build HTTP request
				http_request = build_request(service, method, body, metadata: metadata, timeout: timeout)
				
				# Start the call in a task
				response_task = Async do
					@client.call(http_request)
				end
				
				# Yield the body writer to the caller
				begin
					yield body
				ensure
					body.close_write
				end
				
				# Wait for response
				http_response = response_task.wait
				
				# Wrap response body
				wrap_response_body(http_response, response_class)
				
				# Read single response
				message = http_response.body.read
				
				# Check status
				check_status!(http_response)
				
				message
			end
			
			# Make a bidirectional streaming RPC call
			# @parameter service [String] Service name
			# @parameter method [String] Method name
			# @parameter response_class [Class] Expected response message class
			# @yields {|input, output| ...} Block with input stream and output enumerator
			def bidirectional_streaming(service, method, response_class: nil, metadata: {}, timeout: nil)
				# Build request body
				body = Protocol::GRPC::Body::Writable.new
				
				# Build HTTP request
				http_request = build_request(service, method, body, metadata: metadata, timeout: timeout)
				
				# Start the call
				http_response = @client.call(http_request)
				
				# Wrap response body
				wrap_response_body(http_response, response_class)
				
				# Create output enumerator for reading responses
				# Standard Protocol::HTTP::Body#each returns enumerator of messages
				output = http_response.body.each
				
				# Yield input writer and output reader to caller
				yield body, output
				
				# Ensure body is closed
				body.close_write unless body.closed?
				
				# Check status
				check_status!(http_response)
			end
			
			# Close the underlying HTTP client
			def close
				@client.close
			end
			
			private
			
			def build_request(service, method, body, metadata: {}, timeout: nil)
				path = Protocol::GRPC::Methods.build_path(service, method)
				headers = Protocol::GRPC::Methods.build_headers(
					metadata: metadata,
					timeout: timeout
				)
				
				Protocol::HTTP::Request[
					"POST", path,
					headers: headers,
					body: body,
					scheme: "https",
					authority: @authority
				]
			end
			
			# Wrap response body with gRPC message parser
			# This follows the async-rest pattern of transparent body wrapping
			def wrap_response_body(response, message_class)
				if response.body
					encoding = response.headers["grpc-encoding"]
					response.body = Protocol::GRPC::Body::Readable.new(
						response.body,
						message_class: message_class,
						encoding: encoding
					)
				end
			end
			
		# Check gRPC status and raise error if not OK
			def check_status!(response)
				status = Protocol::GRPC::Metadata.extract_status(response.headers)
				
				return if status == Protocol::GRPC::Status::OK
				
				message = Protocol::GRPC::Metadata.extract_message(response.headers)
				metadata = Protocol::GRPC::Methods.extract_metadata(response.headers)
				
				remote_error = RemoteError.for(message, metadata)
				
				raise Protocol::GRPC::Error.for(status, metadata: metadata), cause: remote_error
			end
		end
	end
end
```

### 2. `Async::GRPC::ServerCall`

Rich context object for server-side RPC handling:

```ruby
module Async
	module GRPC
		# Server-side call context with metadata and deadline tracking
		class ServerCall < Protocol::GRPC::Call
			# @parameter request [Protocol::HTTP::Request]
			# @parameter response_headers [Protocol::HTTP::Headers]
			def initialize(request, response_headers)
				# Parse timeout from grpc-timeout header
				timeout_value = request.headers["grpc-timeout"]
				deadline = if timeout_value
					timeout_seconds = Protocol::GRPC::Methods.parse_timeout(timeout_value)
					Time.now + timeout_seconds if timeout_seconds
				end
				
				super(request, deadline: deadline)
				@response_headers = response_headers
				@response_metadata = {}
				@response_trailers = {}
			end
			
			# @attribute [Protocol::HTTP::Headers] Response headers
			attr :response_headers
			
			# Set response metadata (sent as initial headers)
			# @parameter key [String] Metadata key
			# @parameter value [String] Metadata value
			def set_metadata(key, value)
				@response_metadata[key] = value
				@response_headers[key] = value
			end
			
			# Set response trailer (sent after response body)
			# @parameter key [String] Trailer key
			# @parameter value [String] Trailer value
			def set_trailer(key, value)
				@response_trailers[key] = value
				@response_headers.trailer! unless @response_headers.trailer?
				@response_headers[key] = value
			end
			
			# Abort the RPC with an error
			# @parameter status [Integer] gRPC status code
			# @parameter message [String] Error message
			def abort!(status, message)
				raise Protocol::GRPC::Error.new(status, message)
			end
			
			# Check if we should stop processing
			# @returns [Boolean]
			def should_stop?
				cancelled? || deadline_exceeded?
			end
		end
	end
end
```

### 3. `Async::GRPC::Interceptor`

Middleware/interceptor pattern for client and server:

```ruby
module Async
	module GRPC
		# Base class for client interceptors
		class ClientInterceptor
			# Intercept a client call
			# @parameter service [String] Service name
			# @parameter method [String] Method name
			# @parameter request [Object] Request message
			# @parameter call [Protocol::GRPC::Call] Call context
			# @yields The actual RPC call
			# @returns [Object] Response message
			def call(service, method, request, call)
				yield
			end
		end
		
		# Base class for server interceptors
		class ServerInterceptor
			# Intercept a server call
			# @parameter request [Protocol::HTTP::Request] HTTP request
			# @parameter call [ServerCall] Server call context
			# @yields The actual handler
			# @returns [Protocol::HTTP::Response] HTTP response
			def call(request, call)
				yield
			end
		end
		
		# Example: Logging interceptor
		class LoggingInterceptor < ClientInterceptor
			def call(service, method, request, call)
				Console.logger.info(self){"Calling #{service}/#{method}"}
				start_time = Time.now
				
				begin
					response = yield
					duration = Time.now - start_time
					Console.logger.info(self){"Completed #{service}/#{method} in #{duration}s"}
					response
				rescue => error
					Console.logger.error(self){"Failed #{service}/#{method}: #{error.message}"}
					raise
				end
			end
		end
		
		# Example: Metadata interceptor
		class MetadataInterceptor < ClientInterceptor
			def initialize(metadata = {})
				@metadata = metadata
			end
			
			def call(service, method, request, call)
				# Add metadata to all calls
				call.request.headers.merge!(@metadata)
				yield
			end
		end
	end
end
```

### 4. Using with Async::HTTP::Server

**You don't need a separate `Async::GRPC::Server` class!**

Just use `Protocol::GRPC::Middleware` directly with `Async::HTTP::Server`. The async handling happens automatically because `Protocol::HTTP::Body::Writable` is already async-safe (uses Thread::Queue).

```ruby
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/grpc/middleware"

# Create gRPC middleware
middleware = Protocol::GRPC::Middleware.new
middleware.register("my_service.Greeter", GreeterService.new)

# Use with Async::HTTP::Server - it handles everything!
endpoint = Async::HTTP::Endpoint.parse(
	"https://localhost:50051",
	protocol: Async::HTTP::Protocol::HTTP2
)

server = Async::HTTP::Server.new(middleware, endpoint)

Async do
	server.run
end
```

`Async::HTTP::Server` provides:
- Endpoint binding and connection acceptance
- HTTP/2 protocol handling
- Request/response loop in async tasks
- Connection management

`Protocol::GRPC::Middleware` just implements:
- `call(request) → response`
- Service dispatch
- Message framing
- Error handling

**No additional async wrapper needed!** The protocol middleware is already async-compatible because:
- Handlers can use `Async` tasks internally
- `Body::Writable` uses async-safe queues
- Reading/writing messages doesn't block the reactor

### 3. Service Handler Interface

Service implementations should follow this pattern:

```ruby
module Async
	module GRPC
		# Base class for service handlers (optional, but provides structure)
		class ServiceHandler
			# Each RPC method receives:
			# @parameter input [Protocol::GRPC::Body::Readable] Input message stream
			# @parameter output [Protocol::GRPC::Body::Writable] Output message stream
			# @parameter request [Protocol::HTTP::Request] Original HTTP request (for metadata)
			
			# Example unary RPC:
			def say_hello(input, output, request)
				# Read single request - standard .read method
				hello_request = input.read
				
				# Process
				reply = MyService::HelloReply.new(
					message: "Hello, #{hello_request.name}!"
				)
				
				# Write single response - standard .write method
				output.write(reply)
			end
			
			# Example server streaming RPC:
			def list_features(input, output, request)
				# Read single request
				rectangle = input.read
				
				# Write multiple responses
				10.times do |i|
					feature = MyService::Feature.new(name: "Feature #{i}")
					output.write(feature)
				end
			end
			
			# Example client streaming RPC:
			def record_route(input, output, request)
				# Read multiple requests - standard .each iterator
				points = []
				input.each do |point|
					points << point
				end
				
				# Process and write single response
				summary = MyService::RouteSummary.new(
					point_count: points.size
				)
				output.write(summary)
			end
			
			# Example bidirectional streaming RPC:
			def route_chat(input, output, request)
				# Read and write concurrently
				Async do |task|
					# Read messages in background
					task.async do
						input.each do |note|
							# Process and respond
							response = MyService::RouteNote.new(
								message: "Echo: #{note.message}"
							)
							output.write(response)
						end
					end
				end
			end
		end
	end
end
```

## Usage Examples

### Client Example

```ruby
require "async"
require "async/grpc/client"
require_relative "my_service_pb"

endpoint = Async::HTTP::Endpoint.parse("https://localhost:50051")

Async do
	client = Async::GRPC::Client.new(endpoint)
	
	# Unary RPC
	request = MyService::HelloRequest.new(name: "World")
	response = client.unary(
		"my_service.Greeter",
		"SayHello",
		request,
		response_class: MyService::HelloReply
	)
	puts response.message
	
	# Server streaming RPC
	client.server_streaming(
		"my_service.Greeter",
		"StreamNumbers",
		request,
		response_class: MyService::HelloReply
	) do |reply|
		puts reply.message
	end
	
	# Client streaming RPC
	response = client.client_streaming(
		"my_service.Greeter",
		"RecordRoute",
		response_class: MyService::RouteSummary
	) do |stream|
		10.times do |i|
			point = MyService::Point.new(latitude: i, longitude: i)
			stream.write(point)
		end
	end
	puts response.point_count
	
	# Bidirectional streaming RPC
	client.bidirectional_streaming(
		"my_service.Greeter",
		"RouteChat",
		response_class: MyService::RouteNote
	) do |input, output|
		# Write in background
		task = Async do
			5.times do |i|
				note = MyService::RouteNote.new(message: "Note #{i}")
				input.write(note)
				sleep 0.1
			end
			input.close_write
		end
		
		# Read responses
		output.each do |reply|
			puts reply.message
		end
		
		task.wait
	end
ensure
	client.close
end
```

### Server Example

```ruby
require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/grpc/middleware"
require_relative "my_service_pb"

# Implement service handlers
class GreeterService
	def say_hello(input, output, call)
		hello_request = input.read
		
		reply = MyService::HelloReply.new(
			message: "Hello, #{hello_request.name}!"
		)
		
		output.write(reply)
	end
	
	def stream_numbers(input, output, call)
		hello_request = input.read
		
		10.times do |i|
			reply = MyService::HelloReply.new(
				message: "Number #{i} for #{hello_request.name}"
			)
			output.write(reply)
			sleep 0.1 # Simulate work
		end
	end
end

# Setup server
endpoint = Async::HTTP::Endpoint.parse(
	"https://localhost:50051",
	protocol: Async::HTTP::Protocol::HTTP2
)

Async do
	# Create gRPC middleware
	grpc = Protocol::GRPC::Middleware.new
	grpc.register("my_service.Greeter", GreeterService.new)
	
	# Use with Async::HTTP::Server - no wrapper needed!
	server = Async::HTTP::Server.new(grpc, endpoint)
	
	server.run
end
```

### Integration with Falcon

```ruby
#!/usr/bin/env falcon-host
# frozen_string_literal: true

require "protocol/grpc/middleware"
require_relative "my_service_pb"

class GreeterService
	def say_hello(input, output, call)
		hello_request = input.read
		reply = MyService::HelloReply.new(message: "Hello, #{hello_request.name}!")
		output.write(reply)
	end
end

service "grpc.localhost" do
	include Falcon::Environment::Application
	
	middleware do
		# Just use Protocol::GRPC::Middleware directly!
		grpc = Protocol::GRPC::Middleware.new
		grpc.register("my_service.Greeter", GreeterService.new)
		grpc
	end
	
	scheme "https"
	protocol {Async::HTTP::Protocol::HTTP2}
	
	endpoint do
		Async::HTTP::Endpoint.for(scheme, "localhost", port: 50051, protocol: protocol)
	end
end
```

## Integration with Existing gRPC Libraries

### Channel Adapter for Google Cloud Libraries

Many existing Ruby libraries (like `google-cloud-spanner`) depend on the standard `grpc` gem and expect a `GRPC::Core::Channel` interface. To enable these libraries to use `async-grpc`, we provide a channel adapter.

```ruby
module Async
	module GRPC
		# Adapter that makes Async::GRPC::Client compatible with
		# libraries expecting GRPC::Core::Channel
		class ChannelAdapter
			def initialize(endpoint, channel_args = {}, channel_creds = nil)
				@endpoint = endpoint
				@client = Client.new(endpoint)
				@channel_creds = channel_creds
			end
			
			# Unary RPC: "/package.Service/Method"
			def request_response(path, request, marshal, unmarshal, deadline: nil, metadata: {})
				service, method = parse_path(path)
				metadata = add_auth_metadata(metadata, path) if @channel_creds
				timeout = deadline ? [deadline - Time.now, 0].max : nil
				
				response_binary = Async do
					@client.unary_binary(service, method, marshal.call(request),
						metadata: metadata, timeout: timeout)
				end.wait
				
				unmarshal.call(response_binary)
			end
			
			# Server streaming
			def request_stream(path, request, marshal, unmarshal, deadline: nil, metadata: {})
				# Returns Enumerator of responses
			end
			
			# Client streaming
			def stream_request(path, marshal, unmarshal, deadline: nil, metadata: {})
				# Returns [input_stream, response_future]
			end
			
			# Bidirectional streaming
			def stream_stream(path, marshal, unmarshal, deadline: nil, metadata: {})
				# Returns [input_stream, output_enumerator]
			end
		end
	end
end
```

### Binary Message Interface

To support pre-marshaled protobuf data:

```ruby
class Client
	# Unary with binary data
	def unary_binary(service, method, request_binary, metadata: {}, timeout: nil)
		# Returns binary response (no message_class decoding)
	end
	
	# Server streaming with binary
	def server_streaming_binary(service, method, request_binary, &block)
		# Yields binary strings
	end
end
```

### Usage with Google Cloud

```ruby
require "async/grpc/channel_adapter"
require "google/cloud/spanner"

endpoint = Async::HTTP::Endpoint.parse("https://spanner.googleapis.com")
credentials = Google::Cloud::Spanner::Credentials.default

# Create adapter
channel = Async::GRPC::ChannelAdapter.new(endpoint, {}, credentials)

# Use with Google Cloud libraries
service = Google::Cloud::Spanner::Service.new
service.instance_variable_set(:@channel, channel)

# Now Spanner uses async-grpc!
```

See [`SPANNER_INTEGRATION.md`](SPANNER_INTEGRATION.md) for detailed integration guide.

## Design Decisions

### Client Wraps Async::HTTP::Client

The client is a thin wrapper that:
- Manages the HTTP/2 connection lifecycle
- Handles request/response conversion using `protocol-grpc`
- Provides RPC-style methods (unary, server_streaming, etc.)
- Manages streaming with Async tasks

Benefits:
- Reuses `Async::HTTP::Client` connection pooling
- Automatic HTTP/2 multiplexing
- Async-friendly streaming

### Server: Just Use Existing Infrastructure

**No custom server class needed!** The design is even simpler:

1. `Protocol::GRPC::Middleware` (in protocol-grpc)
   - Implements `call(request) → response`
   - Handles gRPC protocol details
   - Works with any HTTP/2 server

2. `Async::HTTP::Server` (already exists in async-http)
   - Handles endpoint binding
   - Manages connections
   - Runs request/response loop in async tasks

Benefits:
- **No code duplication** - reuse existing Async::HTTP::Server
- **Standard middleware** - works with any Protocol::HTTP::Middleware
- **Composable** - can mix gRPC with HTTP endpoints
- **Simple** - just one middleware class to implement

Compare to Protocol::HTTP ecosystem:
- `Protocol::HTTP::Middleware` - base middleware class
- `Async::HTTP::Server` - uses any middleware
- No need for `Async::HTTP::SpecialServer` - same here!

### Service Handler Interface

Handlers receive `(input, output, request)`:
- `input` - stream for reading request messages
- `output` - stream for writing response messages
- `request` - original HTTP request for accessing metadata

Benefits:
- Uniform interface for all RPC types
- Handlers control streaming explicitly
- Access to metadata via request headers

### Streaming with Async Tasks

Bidirectional streaming uses Async tasks:
- Input and output can be processed concurrently
- Natural async/await patterns
- Proper cleanup on errors

## Google Cloud Integration Requirements

To support Google Cloud libraries (like `google-cloud-spanner`), async-grpc must provide:

### 1. Channel Adapter Interface

Implement `GRPC::Core::Channel` interface methods:
- `request_response(path, request, marshal, unmarshal, deadline:, metadata:)` - Unary
- `request_stream(path, request, marshal, unmarshal, deadline:, metadata:)` - Server streaming
- `stream_request(path, marshal, unmarshal, deadline:, metadata:)` - Client streaming
- `stream_stream(path, marshal, unmarshal, deadline:, metadata:)` - Bidirectional

### 2. Binary Message Support

Support pre-marshaled protobuf data:
- `Client#unary_binary(service, method, request_binary, ...)` → `response_binary`
- `Body::Readable` with `message_class: nil` returns raw binary
- `Body::Writable` accepts binary strings directly

### 3. Authentication Integration

Support Google Cloud authentication patterns:
- OAuth2 access tokens (via credentials object)
- Per-call credential refresh (credentials have `updater_proc`)
- Token metadata format: `{"authorization" => "Bearer ya29.a0..."}`

Example credential integration:
```ruby
# Google's credential format
credentials = Google::Cloud::Spanner::Credentials.default
updater_proc = credentials.client.updater_proc

# For each RPC call:
auth_metadata = updater_proc.call(method_path)
# => {"authorization" => "Bearer ..."}

# Add to request metadata
client.unary(service, method, request, metadata: auth_metadata)
```

### 4. Error Mapping

Map gRPC status codes to Google Cloud errors:
- `Protocol::GRPC::Status::INVALID_ARGUMENT` → `Google::Cloud::InvalidArgumentError`
- `Protocol::GRPC::Status::NOT_FOUND` → `Google::Cloud::NotFoundError`
- `Protocol::GRPC::Status::UNAVAILABLE` → `Google::Cloud::UnavailableError`
- Preserve error messages and metadata

### 5. Metadata Conventions

Support Google Cloud metadata conventions:
- `google-cloud-resource-prefix` - resource path prefix
- `x-goog-spanner-route-to-leader` - leader-aware routing
- `x-goog-request-params` - request routing params
- Custom quota project ID

### 6. Retry Logic Compatibility

Support retry policies from Google Cloud:
- `Gapic::CallOptions` with retry_policy
- Exponential backoff configuration
- Per-method retry settings
- Idempotency awareness

### Implementation Checklist

- [ ] `Async::GRPC::ChannelAdapter` class
- [ ] Binary message methods in `Client`
- [ ] `GRPC::Core::Channel` interface compatibility
- [ ] OAuth2 credential integration
- [ ] Error mapping to Google Cloud errors
- [ ] Metadata convention support
- [ ] Retry policy support
- [ ] Integration tests with actual Spanner SDK

See [`SPANNER_INTEGRATION.md`](SPANNER_INTEGRATION.md) for detailed implementation guide.

### Key Interfaces for Google Cloud Compatibility

**Channel Interface** (from `GRPC::Core::Channel`):
```ruby
channel = ChannelAdapter.new(endpoint, channel_args, channel_creds)
response = channel.request_response(path, request, marshal, unmarshal, deadline:, metadata:)
```

**Binary Client Methods**:
```ruby
client.unary_binary(service, method, binary_request) # => binary_response
client.server_streaming_binary(service, method, binary_request){|binary| do_stuff}
client.client_streaming_binary(service, method){|output| output.write(binary)}
client.bidirectional_streaming_binary(service, method){|input, output| do_stuff}
```

**Authentication Hook**:
```ruby
# Google Cloud credentials provide updater_proc
auth_metadata = credentials.client.updater_proc.call(method_path)
# => {"authorization" => "Bearer ya29.a0..."}
```

This enables async-grpc to be used as a drop-in replacement for the standard `grpc` gem in Google Cloud libraries.

## Implementation Roadmap

### Phase 1: Core Client (✅ Designed)
   - `Async::GRPC::Client` with all four RPC types
   - `Async::GRPC::ServerCall` context object (enhances Protocol::GRPC::Call)
   - Error handling with backtrace support via `RemoteError` and exception chaining
   - Response body wrapping pattern
   - **Server**: Just use `Protocol::GRPC::Middleware` with `Async::HTTP::Server` (no wrapper needed!)

### Phase 2: Google Cloud Integration (✅ Designed)
   - `Async::GRPC::ChannelAdapter` for GRPC::Core::Channel compatibility
   - Binary message methods (`unary_binary`, etc.)
   - OAuth2 authentication integration
   - Google Cloud metadata conventions
   - Error mapping to Google Cloud errors

### Phase 3: Interceptors & Middleware (✅ Designed)
   - `Async::GRPC::ClientInterceptor` base class
   - `Async::GRPC::ServerInterceptor` base class
   - Chain multiple interceptors
   - Built-in interceptors (logging, metrics, auth)

### Phase 4: Advanced Features
   - Retry policies with exponential backoff
   - Flow control & backpressure (bounded queues)
   - Compression negotiation (`grpc-encoding` headers)
   - Health check service implementation
   - Server reflection implementation
   - Graceful shutdown

## Missing/Future Features

### Core Features (Phase 1-2)

1. **Cancellation & Deadlines** (Partially designed)
   - Proper cancellation propagation through async tasks
   - Timeout enforcement for streaming RPCs
   - Cancel ongoing streams when deadline exceeded
   - Context cancellation (similar to Go's context.Context)
   - **Note**: `ServerCall` has deadline tracking, need to wire up cancellation
   
2. **Flow Control & Backpressure**
   - Respect HTTP/2 flow control (handled by async-http)
   - Backpressure for streaming (don't buffer unbounded)
   - Use `Protocol::HTTP::Body::Writable` with bounded queue option

### Advanced Features (Later)

5. **Health Checking**
   - Standard gRPC health check protocol
   - `grpc.health.v1.Health` service
   - Per-service health status

6. **Reflection API**
   - Server reflection protocol (grpc.reflection.v1alpha.ServerReflection)
   - Allows tools like `grpcurl` to discover services
   - List services, describe methods, get proto definitions

7. **Authentication & Authorization**
   - Channel credentials (TLS, custom auth)
   - Per-call credentials (tokens, API keys)
   - Integration with standard auth patterns

8. **Retry Policies**
   - Automatic retries with exponential backoff
   - Configurable retry conditions (status codes)
   - Hedging (parallel requests)

9. **Load Balancing**
   - Client-side load balancing
   - Service config (retry policy, timeout, LB config)
   - Integration with service discovery

10. **Compression Negotiation**
    - `grpc-encoding` header support
    - `grpc-accept-encoding` for advertising support
    - Multiple compression algorithms (gzip, deflate, etc.)

## Open Questions

1. **Interceptor API**: What should the interface be?
   ```ruby
class LoggingInterceptor
	def call(request, call)
		# Before request
		result = yield
		# After response
		result
	end
end
   ```

2. **Context/Call Object**: Should we have a rich call context?
   - Access metadata, peer info, deadline
   - Set trailers, check cancellation
   - Pass context through interceptors

3. **Connection Pooling**: Client-side or server-side?
   - Current: Single Async::HTTP::Client
   - Could pool multiple connections
   - Or rely on HTTP/2 multiplexing?

4. **Graceful Shutdown**: How should server shutdown work?
   - Stop accepting new calls
   - Wait for in-flight calls to complete
   - Force close after timeout

5. **Error Propagation**: How to handle partial failures in streaming?
   - Close stream immediately on error?
   - Send error in trailers?
   - Allow partial success?

6. **Type Validation**: Validate message types at runtime?
   - Check message class matches expected type
   - Or trust duck typing?

## References

- [Protocol::GRPC Design](../protocol-grpc/design.md)
- [Async::HTTP](https://github.com/socketry/async-http)
- [Protocol::HTTP::Middleware](https://github.com/socketry/protocol-http)
- [gRPC Core Concepts](https://grpc.io/docs/what-is-grpc/core-concepts/)

