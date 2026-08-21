# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.
# Copyright, 2026, by Alex Watt.

require "async"

require_relative "error"

require "protocol/grpc/middleware"
require "protocol/grpc/call"
require "protocol/grpc/route"
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
			
			# Called once after the final gRPC status has been assigned.
			#
			# Override this method to record request metrics or logs. The hook also runs for
			# routing/setup failures and after streaming calls finish. A cancelled call has
			# a status of `Protocol::GRPC::Status::CANCELLED` and no error.
			#
			# Exceptions raised by this hook are ignored.
			#
			# @parameter call [Protocol::GRPC::Call] The call context, including the request and the response.
			# @parameter error [Exception | Nil] The error which caused the call to fail, if any.
			# @returns [void]
			# @example Record the final gRPC status code
			# 	def emit_completion(call, error = nil)
			# 		service_name, method_name = Protocol::GRPC::Route.parse(call.request.path)
			# 		metrics.increment("grpc.request", tags: {service: service_name, method: method_name, status: call.status})
			# 	end
			def emit_completion(call, error = nil)
				# Implementation-defined.
			end
			
			# Invoke a service handler.
			#
			# Override this method to establish request context or wrap handlers with
			# application middleware. Overrides should call `super` to invoke the handler.
			# Stream cleanup, trailer handling, and status assignment are performed by the
			# dispatcher after this method returns or raises.
			#
			# This hook only surrounds service execution. Use {emit_completion} to observe
			# every request, including routing/setup failures. A deadline expiring during
			# service execution raises {DeadlineExceededError} through this hook before it is
			# converted to `DEADLINE_EXCEEDED`.
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
				service.send(handler_method, input, output, call)
			end
			
			# Map an internal dispatcher error to the gRPC status and message reported to the client.
			#
			# @parameter error [Exception] The error which caused the call to fail.
			# @returns [Tuple(Integer, String | Nil)] The gRPC status code and message.
			private def status_for(error)
				case error
				when DeadlineExceededError
					return Protocol::GRPC::Status::DEADLINE_EXCEEDED, "Deadline exceeded!"
				when Protocol::GRPC::Error
					return error.status_code, error.message
				else
					# A `nil` message defers to the message of the error itself:
					return Protocol::GRPC::Status::INTERNAL, nil
				end
			end
			
			# Invoke the service with deadline enforcement and completion reporting.
			#
			# @parameter parent [Async::Task] The task used to enforce the call deadline.
			def dispatch_to_service(service, handler_method, input, output, call, parent: Async::Task.current)
				error = nil
				cancellation = nil
				
				begin
					if deadline = call.deadline
						parent.with_timeout(deadline.remaining, DeadlineExceededError) do
							invoke_service(service, handler_method, input, output, call)
						end
					else
						invoke_service(service, handler_method, input, output, call)
					end
				rescue => error
					prepare_trailers(output, call)
					assign_status(call, error)
				rescue Async::Stop => cancellation
					prepare_trailers(output, call)
					
					# Cancellation has a fixed status and does not require error mapping:
					if headers = call.response&.headers
						Protocol::GRPC::Metadata.assign_status!(headers, status: Protocol::GRPC::Status::CANCELLED)
					end
					
					raise
				else
					prepare_trailers(output, call)
					
					# Add status (if not already set by handler):
					if headers = call.response&.headers
						unless headers.key?("grpc-status")
							Protocol::GRPC::Metadata.assign_status!(headers, status: Protocol::GRPC::Status::OK)
						end
					end
				ensure
					finalize_streams(input, output, call, error, cancellation)
				end
			end
			
			# Mark response headers as trailers when data was written.
			def prepare_trailers(output, call)
				if output.count > 0
					call.response.headers.trailer!
				end
			end
			
			# Close the input and output streams.
			def close_streams(input, output, call)
				# Close input stream:
				input.close
			ensure
				# Close output stream:
				unless output.closed?
					output.close_write
				end
			end
			
			# Close streams and report completion while preserving an active service error or cancellation.
			private def finalize_streams(input, output, call, error, cancellation)
				close_streams(input, output, call)
			rescue => close_error
				if error || cancellation
					Console.warn(self, "Error during stream cleanup!", exception: close_error)
				else
					error = close_error
					assign_status(call, error)
					raise
				end
			ensure
				# Cancellation raises `Async::Stop`, not `StandardError`:
				report_completion(call, error)
			end
			
			# Assign the status for the given error to the response.
			def assign_status(call, error)
				if headers = call.response&.headers
					begin
						status, message = status_for(error)
					rescue => internal_error
						Console.warn(self, "Error during status mapping!", exception: internal_error)
						
						status = Protocol::GRPC::Status::INTERNAL
						message = nil
					end
					
					Protocol::GRPC::Metadata.assign_status!(headers, status: status, message: message, error: error)
				end
			end
			
			# Report completion without allowing instrumentation to affect the request.
			private def report_completion(call, error = nil)
				emit_completion(call, error)
			rescue => error
				Console.warn(self, "Error during emit completion!", exception: error)
			end
			
			# Dispatch the request to the appropriate service.
			# @parameter request [Protocol::HTTP::Request] The HTTP request
			# @returns [Protocol::HTTP::Response] The HTTP response
			def dispatch(request)
				# Create response headers:
				encoding = request.headers["grpc-encoding"]
				response_headers = Protocol::HTTP::Headers.new([], nil, policy: Protocol::GRPC::HEADER_POLICY)
				response_headers["content-type"] = "application/grpc+proto"
				response_headers["grpc-encoding"] = encoding if encoding
				
				# Assign the body after routing so setup failures are trailers-only:
				response = Protocol::HTTP::Response[200, response_headers, nil]
				call = nil
				
				begin
					# Create the call context:
					call = Protocol::GRPC::Call.for(request, response)
					
					# Extract the routing information from the request path:
					service_name, method_name = Protocol::GRPC::Route.parse(request.path)
					
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
					input = Protocol::GRPC::Body::ReadableBody.new(request.body, message_class: request_class, encoding: encoding)
					output = Protocol::GRPC::Body::WritableBody.new(message_class: response_class, encoding: encoding)
					response.body = output
				rescue => error
					# Routing/setup failures. {Protocol::GRPC::Call.for} can fail before the call context exists:
					call ||= Protocol::GRPC::Call.new(request, response)
					
					assign_status(call, error)
					report_completion(call, error)
					
					return response
				end
				
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
