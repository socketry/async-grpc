# Getting Started

This guide explains how to get started with `Async::GRPC` for building gRPC clients and servers.

## Installation

Add the gem to your project:

~~~ bash
$ bundle add async-grpc
~~~

You'll also need `protocol-grpc` and `async-http`:

~~~ bash
$ bundle add protocol-grpc async-http
~~~

## Core Concepts

`async-grpc` provides:

  - {ruby Async::GRPC::Client} - An asynchronous gRPC client that wraps `Async::HTTP::Client`.
  - {ruby Async::GRPC::Stub} - A method-based stub for making RPC calls.
  - {ruby Async::GRPC::Service} - A concrete service implementation that uses a `Protocol::GRPC::Interface`.
  - {ruby Async::GRPC::Dispatcher} - Middleware that routes requests to registered services.

## Client Usage

### Creating a Client

``` ruby
require "async/grpc"
require "async/http/endpoint"

endpoint = Async::HTTP::Endpoint.parse("https://grpc.example.com")
http_client = Async::HTTP::Client.new(endpoint)
client = Async::GRPC::Client.new(http_client)
```

### Using a Stub

Create a stub from an interface definition:

``` ruby
# Define the interface
class GreeterInterface < Protocol::GRPC::Interface
	rpc :SayHello, request_class: Hello::HelloRequest, response_class: Hello::HelloReply
end

# Create a stub
stub = client.stub(GreeterInterface, "hello.Greeter")

# Make RPC calls (accepts both snake_case and PascalCase)
response = stub.say_hello(Hello::HelloRequest.new(name: "World"))
# or
response = stub.SayHello(Hello::HelloRequest.new(name: "World"))
```

### Streaming RPCs

``` ruby
# Server streaming
stub.server_streaming_call(request) do |response|
	puts response.value
end

# Client streaming
stub.client_streaming_call do |output|
	output.write(request1)
	output.write(request2)
end

# Bidirectional streaming
stub.bidirectional_streaming do |input, output|
	input.each do |request|
		output.write(process(request))
	end
end
```

## Server Usage

### Defining a Service

``` ruby
require "async/grpc/service"

# Define the interface
class GreeterInterface < Protocol::GRPC::Interface
	rpc :SayHello, request_class: Hello::HelloRequest, response_class: Hello::HelloReply
end

# Implement the service
class GreeterService < Async::GRPC::Service
	def say_hello(input, output, call)
		request = input.read
		reply = Hello::HelloReply.new(message: "Hello, #{request.name}!")
		output.write(reply)
	end
end
```

### Registering Services

``` ruby
require "async/grpc/dispatcher"

dispatcher = Async::GRPC::Dispatcher.new

service = GreeterService.new(GreeterInterface, "hello.Greeter")
dispatcher.register(service)
```

### Running a Server

``` ruby
require "async/http/server"
require "async/http/endpoint"

endpoint = Async::HTTP::Endpoint.parse("http://localhost:50051")
server = Async::HTTP::Server.for(endpoint, dispatcher)

Async do
	server.run
end
```

### Instrumentation

Subclass the dispatcher and override {ruby Async::GRPC::Dispatcher#emit_completion} to record completion metrics or logs.
The hook runs once per request after the final gRPC status is assigned, including routing failures and completed streaming calls:

``` ruby
class InstrumentedDispatcher < Async::GRPC::Dispatcher
	protected
	
	def emit_completion(call, error = nil)
		Console.info(self, "Request completed!", path: call.request.path, status: call.status)
	end
end
```

A cancelled request has a status of `Protocol::GRPC::Status::CANCELLED` and no `error`. Exceptions raised by the hook are logged and ignored.

To map application-specific errors onto gRPC statuses, override {ruby Async::GRPC::Dispatcher#status_for}:

``` ruby
class ApplicationDispatcher < Async::GRPC::Dispatcher
	protected
	
	def status_for(error)
		case error
		when ActiveRecord::RecordNotFound
			return Protocol::GRPC::Status::NOT_FOUND, error.message
		else
			super
		end
	end
end
```

Override {ruby Async::GRPC::Dispatcher#invoke_service} when you need middleware around service execution:

``` ruby
class ApplicationDispatcher < Async::GRPC::Dispatcher
	protected
	
	def invoke_service(service, handler_method, input, output, call)
		RequestContext.for(call.request) do
			super
		end
	end
end
```

## Complete Example

``` ruby
require "async"
require "async/grpc"
require "async/http/server"
require "async/http/endpoint"

# Define interface
class GreeterInterface < Protocol::GRPC::Interface
	rpc :SayHello, request_class: Hello::HelloRequest, response_class: Hello::HelloReply
end

# Implement service
class GreeterService < Async::GRPC::Service
	def say_hello(input, output, call)
		request = input.read
		reply = Hello::HelloReply.new(message: "Hello, #{request.name}!")
		output.write(reply)
	end
end

Async do
		# Setup server
	endpoint = Async::HTTP::Endpoint.parse("http://localhost:50051")
	dispatcher = Async::GRPC::Dispatcher.new
	dispatcher.register(GreeterService.new(GreeterInterface, "hello.Greeter"))
	server = Async::HTTP::Server.for(endpoint, dispatcher)
	
		# Setup client
	client_endpoint = Async::HTTP::Endpoint.parse("http://localhost:50051")
	http_client = Async::HTTP::Client.new(client_endpoint)
	client = Async::GRPC::Client.new(http_client)
	stub = client.stub(GreeterInterface, "hello.Greeter")
	
		# Make a call
	request = Hello::HelloRequest.new(name: "World")
	response = stub.say_hello(request)
	puts response.message  # => "Hello, World!"
	
	server.run
end
```
