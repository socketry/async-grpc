# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "async"
require "async/deadline"

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
		# Dispatches gRPC requests to registered services.
		# Handles routing based on service name from the request path.
		#
		# @example Registering services:
		#   dispatcher = Dispatcher.new
		#   dispatcher.register(GreeterService.new(GreeterInterface, "hello.Greeter"))
		#   dispatcher.register(WorldService.new(WorldInterface, "world.Greeter"))
		#
		#   server = Async::HTTP::Server.for(endpoint, dispatcher)
		class Dispatcher < Protocol::GRPC::Middleware
			# Initialize the dispatcher.
			# @parameter app [#call | Nil] The next middleware in the chain
			# @parameter services [Hash] Optional initial services hash (service_name => service_instance)
			def initialize(app = nil, services: {})
				super(app)
				@services = services
			end
			
		# Register a service.
		# @parameter service [Async::GRPC::Service] Service instance
		# @parameter name [String] Service name (defaults to service.service_name)
		def register(service, name: service.service_name)
			@services[name] = service
		end
			
			protected
			
			def invoke_service(service, handler_method, input, output, call)
				begin
					service.send(handler_method, input, output, call)
				ensure
					# Close input stream:
					input.close
					
					# Close output stream:
					output.close_write unless output.closed?
				end
				
				# Mark trailers and add status (if not already set by handler):
				if call.response&.headers
					call.response.headers.trailer!
					
					# Only add OK status if grpc-status hasn't been set by the handler:
					unless call.response.headers["grpc-status"]
						Protocol::GRPC::Metadata.add_status!(call.response.headers, status: Protocol::GRPC::Status::OK)
					end
				end
			end
			
			def dispatch_to_service(service, handler_method, input, output, call, deadline, parent: Async::Task.current)
				if deadline
					parent.with_timeout(deadline) do
						invoke_service(service, handler_method, input, output, call)
					end
				else
					invoke_service(service, handler_method, input, output, call)
				end
			end
			
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
				
				handler_method = rpc_descriptor.method
				request_class = rpc_descriptor.request_class
				response_class = rpc_descriptor.response_class
				
				# Verify handler method exists:
				unless service.respond_to?(handler_method, true)
					raise Protocol::GRPC::Error.new(Protocol::GRPC::Status::UNIMPLEMENTED, "Handler method not implemented: #{handler_method}")
				end
				
				# Create protocol-level objects for gRPC handling:
				encoding = request.headers["grpc-encoding"]
				input = Protocol::GRPC::Body::ReadableBody.new(request.body, message_class: request_class, encoding: encoding)
				output = Protocol::GRPC::Body::WritableBody.new(message_class: response_class, encoding: encoding)
				
				# Create response headers:
				response_headers = Protocol::HTTP::Headers.new([], nil, policy: Protocol::GRPC::HEADER_POLICY)
				response_headers["content-type"] = "application/grpc+proto"
				response_headers["grpc-encoding"] = encoding if encoding
				
				# Create response object:
				response = Protocol::HTTP::Response[200, response_headers, output]
				
				# Parse deadline from timeout header:
				timeout = Protocol::GRPC::Methods.parse_timeout(request.headers["grpc-timeout"])
				deadline = if timeout
					Async::Deadline.start(timeout)
				end
				
				# Create call context with request and response:
				call = Protocol::GRPC::Call.new(request, response, deadline: deadline)
				
				if rpc_descriptor.streaming?
					Async do |task|
						dispatch_to_service(service, handler_method, input, output, call, deadline, parent: task)
					end
				else
					# Unary call:
					dispatch_to_service(service, handler_method, input, output, call, deadline)
				end
				
				response
			end
		end
	end
end
