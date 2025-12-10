# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "protocol/grpc/middleware"
require "protocol/grpc/methods"
require "protocol/grpc/call"
require "protocol/grpc/body/readable_body"
require "protocol/grpc/body/writable_body"
require "protocol/grpc/metadata"
require "protocol/grpc/error"
require "protocol/grpc/status"

module Async
	module GRPC
		# Represents middleware that dispatches gRPC requests to registered services.
		# Handles routing based on service name from the request path.
		#
		# @example Registering services:
		#   dispatcher = DispatcherMiddleware.new
		#   dispatcher.register("hello.Greeter", GreeterService.new(GreeterInterface, "hello.Greeter"))
		#   dispatcher.register("world.Greeter", WorldService.new(WorldInterface, "world.Greeter"))
		#
		#   server = Async::HTTP::Server.for(endpoint, dispatcher)
		class DispatcherMiddleware < Protocol::GRPC::Middleware
			# Initialize the dispatcher.
			# @parameter app [#call | Nil] The next middleware in the chain
			# @parameter services [Hash] Optional initial services hash (service_name => service_instance)
			def initialize(app = nil, services: {})
				super(app)
				@services = services
			end
			
			# Register a service.
			# @parameter service_name [String] Service name (e.g., "hello.Greeter")
			# @parameter service [Async::GRPC::Service] Service instance
			def register(service_name, service)
				@services[service_name] = service
			end
			
			protected
			
			# Dispatch the request to the appropriate service.
			# @parameter request [Protocol::HTTP::Request] The HTTP request
			# @returns [Protocol::HTTP::Response] The HTTP response
			# @raises [Protocol::GRPC::Error] If service or method is not found
			def dispatch(request)
				# Parse service and method from path:
				service_name, method_name = Protocol::GRPC::Methods.parse_path(request.path)
				
				# Find service:
				service = @services[service_name]
				unless service
					raise Protocol::GRPC::Error.new(Protocol::GRPC::Status::UNIMPLEMENTED, "Service not found: #{service_name}")
				end
				
				# Verify service name matches:
				unless service_name == service.service_name
					raise Protocol::GRPC::Error.new(Protocol::GRPC::Status::UNIMPLEMENTED, "Service name mismatch: expected #{service.service_name}, got #{service_name}")
				end
				
				# Get RPC descriptions from the service:
				rpc_descriptor = service.rpc_descriptions[method_name]
				unless rpc_descriptor
					raise Protocol::GRPC::Error.new(Protocol::GRPC::Status::UNIMPLEMENTED, "Method not found: #{method_name}")
				end
				
				handler_method = rpc_descriptor[:method]
				request_class = rpc_descriptor[:request_class]
				response_class = rpc_descriptor[:response_class]
				
				# Verify handler method exists:
				unless service.respond_to?(handler_method, true)
					raise Protocol::GRPC::Error.new(Protocol::GRPC::Status::UNIMPLEMENTED, "Handler method not implemented: #{handler_method}")
				end
				
				# Create protocol-level objects for gRPC handling:
				encoding = request.headers["grpc-encoding"]
				input = Protocol::GRPC::Body::ReadableBody.new(request.body, message_class: request_class, encoding: encoding)
				output = Protocol::GRPC::Body::WritableBody.new(message_class: response_class, encoding: encoding)
				
				# Create call context:
				response_headers = Protocol::HTTP::Headers.new([], nil, policy: Protocol::GRPC::HEADER_POLICY)
				response_headers["content-type"] = "application/grpc+proto"
				response_headers["grpc-encoding"] = encoding if encoding
				
				# Parse deadline from timeout header:
				timeout_value = request.headers["grpc-timeout"]
				deadline = if timeout_value
					timeout_seconds = Protocol::GRPC::Methods.parse_timeout(timeout_value)
					require "async/deadline"
					Async::Deadline.start(timeout_seconds) if timeout_seconds
				end
				
				call = Protocol::GRPC::Call.new(request, deadline: deadline)
				
				# Call the handler method on the service:
				service.send(handler_method, input, output, call)
				
				# Close output stream:
				output.close_write unless output.closed?
				
				# Mark trailers and add status:
				response_headers.trailer!
				Protocol::GRPC::Metadata.add_status_trailer!(response_headers, status: Protocol::GRPC::Status::OK)
				
				Protocol::HTTP::Response[200, response_headers, output]
			end
		end
	end
end

