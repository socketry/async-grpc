# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async"

require_relative "error"

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
			
			# Invoke a service handler, providing a protected extension point for middleware and instrumentation around service execution.
			#
			# Override this method to observe service outcomes, establish request context, or wrap handlers with application middleware. Overrides should call `super` to invoke the handler and preserve the dispatcher's stream cleanup, trailer handling, and successful status assignment.
			#
			# This hook only surrounds service handler execution. Errors raised earlier while routing or preparing the request do not pass through it. A call deadline that expires during service execution raises {DeadlineExceededError} through this hook before the dispatcher converts it to a `DEADLINE_EXCEEDED` response.
			#
			# @parameter service [Async::GRPC::Service] The service containing the handler.
			# @parameter handler_method [Symbol] The service method to invoke.
			# @parameter input [Protocol::GRPC::Body::ReadableBody] The decoded request stream.
			# @parameter output [Protocol::GRPC::Body::WritableBody] The response stream.
			# @parameter call [Protocol::GRPC::Call] The call context.
			# @returns [Object | Nil] An internal dispatch result with no stable application-facing contract.
			# @example Wrap service execution with application middleware
			# 	def invoke_service(service, handler_method, input, output, call)
			# 		context = RequestContext.new(call.request)
			# 		middleware.call(context) do
			# 			super
			# 		end
			# 	end
			def invoke_service(service, handler_method, input, output, call)
				begin
					service.send(handler_method, input, output, call)
				ensure
					# Close input stream:
					input.close
					
					# Close output stream:
					output.close_write unless output.closed?
					
					# gRPC supports trailers-only responses, but only if there are no data frames. If at this point, there are data frames (which may or may not have been sent yet), we need to mark trailers:
					if output.count > 0
						call.response.headers.trailer!
					end
				end
				
				# Add status (if not already set by handler):
				if headers = call.response&.headers
					# Only add OK status if grpc-status hasn't been set by the handler:
					unless headers.key?("grpc-status")
						Protocol::GRPC::Metadata.assign_status!(headers, status: Protocol::GRPC::Status::OK)
					end
				end
			end
			
			def dispatch_to_service(service, handler_method, input, output, call, parent: Async::Task.current)
				if deadline = call.deadline
					parent.with_timeout(deadline.remaining, DeadlineExceededError) do
						invoke_service(service, handler_method, input, output, call)
					end
				else
					invoke_service(service, handler_method, input, output, call)
				end
			rescue DeadlineExceededError => error
				# Close input and output streams:
				input.close
				output.close_write unless output.closed?
				
				# Set DEADLINE_EXCEEDED status in trailers:
				if headers = call.response&.headers
					Protocol::GRPC::Metadata.assign_status!(headers, status: Protocol::GRPC::Status::DEADLINE_EXCEEDED, message: "Deadline exceeded!", error: error)
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
				
				# Create call context with request, response and deadline:
				call = Protocol::GRPC::Call.for(request, response)
				
				if rpc_descriptor.streaming?
					Async do |task|
						dispatch_to_service(service, handler_method, input, output, call, parent: task)
					end
				else
					# Unary call:
					dispatch_to_service(service, handler_method, input, output, call)
				end
				
				return response
			end
		end
	end
end
