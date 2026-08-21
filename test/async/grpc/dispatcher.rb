# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "sus/fixtures/async/scheduler_context"

require "async/grpc/dispatcher"
require "async/grpc/service"
require "protocol/http"
require "protocol/grpc/route"
require "protocol/grpc/metadata"
require "protocol/grpc/body/writable_body"
require "async/grpc/test_interface"

describe Async::GRPC::Dispatcher do
	include Sus::Fixtures::Async::SchedulerContext
	
	let(:service_name) {"test.Service"}
	let(:service) {Async::GRPC::Fixtures::TestService.new(Async::GRPC::Fixtures::TestInterface, service_name)}
	let(:dispatcher) {subject.new(services: {service_name => service})}
	
	# A dispatcher which records every {Async::GRPC::Dispatcher#emit_completion} invocation.
	# An optional block is evaluated in the subclass in order to override other hooks.
	def recording_dispatcher(services, &block)
		dispatcher_class = Class.new(subject) do
			def completions
				@completions ||= []
			end
			
			protected
			
			def emit_completion(call, status:, error: nil)
				completions << {call: call, status: status, error: error, response_status: Protocol::GRPC::Metadata.extract_status(call.response.headers)}
			end
		end
		
		dispatcher_class.class_eval(&block) if block
		
		dispatcher_class.new(services: services)
	end
	
	# A service whose only method raises the given error.
	def raising_service(name, error)
		interface = Class.new(Protocol::GRPC::Interface) do
			rpc :RaiseError, request_class: Protocol::GRPC::Fixtures::TestMessage,
				response_class: Protocol::GRPC::Fixtures::TestMessage, streaming: :unary
		end
		
		Class.new(Async::GRPC::Service) do
			define_method(:raise_error) do |input, _output, _call|
				input.read
				raise error
			end
		end.new(interface, name)
	end
	
	with "#register" do
		it "can register a service" do
			dispatcher = subject.new
			dispatcher.register(service)
			expect(dispatcher.instance_variable_get(:@services)[service_name]).to be == service
		end
		
		it "can register a service with custom name" do
			dispatcher = subject.new
			custom_name = "custom.Service"
			dispatcher.register(service, name: custom_name)
			expect(dispatcher.instance_variable_get(:@services)[custom_name]).to be == service
		end
	end
	
	with "#call" do
		let(:request_body) do
			Protocol::GRPC::Body::WritableBody.new.tap do |body|
				request_message = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
				body.write(request_message)
				body.close_write
			end
		end
		
		let(:headers) {Protocol::GRPC::Metadata.build}
		let(:path) {Protocol::GRPC::Route.build(service_name, "UnaryCall")}
		let(:request) {Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)}
		
		# Build a request for the given service method.
		def build_request(service_name, method_name, body: request_body)
			path = Protocol::GRPC::Route.build(service_name, method_name)
			
			Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, body)
		end
		
		# Read the response to completion so that the trailers are available.
		def consume_response(response)
			body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: Protocol::GRPC::Fixtures::TestMessage)
			body.each{|_message|}
			body.finish
		end
		
		it "dispatches to registered service" do
			response = dispatcher.call(request)
			
			expect(response.status).to be == 200
			expect(response.headers["content-type"]).to be == "application/grpc+proto"
			
			# Read response - response.body is a WritableBody that can be read directly
			response_body = Protocol::GRPC::Body::ReadableBody.new(response.body, message_class: Protocol::GRPC::Fixtures::TestMessage)
			response_message = response_body.read
			expect(response_message).not.to be_nil
			expect(response_message.value).to be == "Response: test"
		end
		
		it "handles CamelCase method names" do
			response = dispatcher.call(build_request(service_name, "SayHello"))
			expect(response.status).to be == 200
			
			response_body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: Protocol::GRPC::Fixtures::TestMessage)
			
			response_message = response_body.read
			expect(response_message).not.to be_nil
			expect(response_message.value).to be == "Hello, test!"
		end
		
		it "returns UNIMPLEMENTED for unknown service" do
			response = dispatcher.call(build_request("unknown.Service", "UnaryCall"))
			expect(response.status).to be == 200 # gRPC uses trailers for errors
			
			status = Protocol::GRPC::Metadata.extract_status(response.headers)
			expect(status).to be == Protocol::GRPC::Status::UNIMPLEMENTED
		end
		
		it "returns UNIMPLEMENTED for unknown method" do
			response = dispatcher.call(build_request(service_name, "UnknownMethod"))
			
			status = Protocol::GRPC::Metadata.extract_status(response.headers)
			expect(status).to be == Protocol::GRPC::Status::UNIMPLEMENTED
		end
		
		it "returns UNIMPLEMENTED when the registered service name does not match" do
			registered_name = "alias.Service"
			dispatcher = subject.new(services: {registered_name => service})
			
			response = dispatcher.call(build_request(registered_name, "UnaryCall"))
			
			expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::UNIMPLEMENTED
			expect(Protocol::GRPC::Metadata.extract_message(response.headers)).to be == "Service name mismatch: expected test.Service, got alias.Service"
		end
		
		it "returns UNIMPLEMENTED when the service handler is missing" do
			interface_class = Class.new(Protocol::GRPC::Interface) do
				rpc :MissingCall,
					request_class: Protocol::GRPC::Fixtures::TestMessage,
					response_class: Protocol::GRPC::Fixtures::TestMessage
			end
			service_name = "test.IncompleteService"
			service = Async::GRPC::Service.new(interface_class, service_name)
			dispatcher = subject.new(services: {service_name => service})
			
			response = dispatcher.call(build_request(service_name, "MissingCall"))
			
			expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::UNIMPLEMENTED
			expect(Protocol::GRPC::Metadata.extract_message(response.headers)).to be == "Handler method not implemented: missing_call"
		end
		
		it "passes non-gRPC requests to next middleware" do
			next_middleware = proc{Protocol::HTTP::Response[404, {}, ["Not Found"]]}
			dispatcher = subject.new(next_middleware, services: { service_name => service })
			
			non_grpc_request = Protocol::HTTP::Request.new("http", "localhost", "GET", "/", nil, Protocol::HTTP::Headers.new,
				nil)
			response = dispatcher.call(non_grpc_request)
			
			expect(response.status).to be == 404
		end
		
		it "handles timeout correctly" do
			request = build_request(service_name, "SlowCall")
			request.headers["grpc-timeout"] = "100m" # 100 milliseconds
			
			response = dispatcher.call(request)
			
			expect(response.status).to be == 200
			
			# The response body should be consumed to access trailers:
			consume_response(response)
			
			# Check that grpc-status is DEADLINE_EXCEEDED (4):
			status = Protocol::GRPC::Metadata.extract_status(response.headers)
			expect(status).to be == Protocol::GRPC::Status::DEADLINE_EXCEEDED
			
			message = Protocol::GRPC::Metadata.extract_message(response.headers)
			expect(message).to be == "Deadline exceeded!"
		end
		
		with "#emit_completion" do
			it "emits completion with OK status for successful requests" do
				dispatcher = recording_dispatcher(service_name => service)
				
				response = dispatcher.call(request)
				consume_response(response)
				
				expect(dispatcher.completions.size).to be == 1
				
				completion = dispatcher.completions.last
				expect(completion[:call].request).to be == request
				expect(completion[:call].response).to be == response
				expect(completion[:status]).to be == Protocol::GRPC::Status::OK
				expect(completion[:error]).to be_nil
				# The status is assigned to the response before the completion is emitted:
				expect(completion[:response_status]).to be == Protocol::GRPC::Status::OK
			end
			
			it "emits completion after streaming requests finish" do
				dispatcher = recording_dispatcher(service_name => service)
				
				response = dispatcher.call(build_request(service_name, "ServerStreamingCall"))
				consume_response(response)
				
				expect(dispatcher.completions.size).to be == 1
				
				completion = dispatcher.completions.last
				expect(completion[:status]).to be == Protocol::GRPC::Status::OK
				expect(completion[:error]).to be_nil
			end
			
			it "emits completion when a streaming request is cancelled" do
				dispatcher = recording_dispatcher(service_name => service)
				# Keep the request open so that the service blocks on input:
				request = build_request(service_name, "BidirectionalCall", body: Protocol::GRPC::Body::WritableBody.new)
				
				# The dispatch task is a child of this task, so stopping it simulates cancellation:
				task = Async{dispatcher.call(request)}
				task.stop
				
				expect(dispatcher.completions.size).to be == 1
				
				completion = dispatcher.completions.last
				# Cancellation does not assign an error status:
				expect(completion[:status]).to be == Protocol::GRPC::Status::UNKNOWN
				expect(completion[:error]).to be_nil
			end
			
			it "emits completion for unknown service" do
				dispatcher = recording_dispatcher(service_name => service)
				
				dispatcher.call(build_request("unknown.Service", "UnaryCall"))
				
				expect(dispatcher.completions.size).to be == 1
				
				completion = dispatcher.completions.last
				expect(completion[:status]).to be == Protocol::GRPC::Status::UNIMPLEMENTED
				expect(completion[:error]).to be_a(Protocol::GRPC::Error)
			end
			
			it "emits completion when the call context cannot be created" do
				dispatcher = recording_dispatcher(service_name => service)
				# An unparseable deadline makes `Protocol::GRPC::Call.for` fail before the call context exists:
				request.headers["grpc-timeout"] = "invalid"
				
				response = dispatcher.call(request)
				
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::INTERNAL
				expect(response.body).to be_nil
				
				expect(dispatcher.completions.size).to be == 1
				
				completion = dispatcher.completions.last
				# The fallback call context wraps the original request and response:
				expect(completion[:call].request).to be == request
				expect(completion[:call].response).to be == response
				expect(completion[:status]).to be == Protocol::GRPC::Status::INTERNAL
				expect(completion[:error]).to be_a(ArgumentError)
			end
			
			it "emits completion with DEADLINE_EXCEEDED status for timeouts" do
				dispatcher = recording_dispatcher(service_name => service)
				request = build_request(service_name, "SlowCall")
				request.headers["grpc-timeout"] = "100m" # 100 milliseconds
				
				response = dispatcher.call(request)
				consume_response(response)
				
				expect(dispatcher.completions.size).to be == 1
				
				completion = dispatcher.completions.last
				expect(completion[:status]).to be == Protocol::GRPC::Status::DEADLINE_EXCEEDED
				expect(completion[:error]).to be_a(Async::GRPC::DeadlineExceededError)
			end
			
			it "emits completion with the status from a Protocol::GRPC::Error" do
				error_service_name = "test.ErrorService"
				error_service = raising_service(error_service_name, Protocol::GRPC::Error.new(Protocol::GRPC::Status::RESOURCE_EXHAUSTED, "too many requests"))
				dispatcher = recording_dispatcher(error_service_name => error_service)
				
				response = dispatcher.call(build_request(error_service_name, "RaiseError"))
				
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::RESOURCE_EXHAUSTED
				
				completion = dispatcher.completions.last
				expect(completion[:status]).to be == Protocol::GRPC::Status::RESOURCE_EXHAUSTED
				expect(completion[:error]).to be_a(Protocol::GRPC::Error)
			end
			
			it "emits completion with INTERNAL status for unexpected errors" do
				error_service_name = "test.UnexpectedErrorService"
				error_service = raising_service(error_service_name, RuntimeError.new("boom"))
				dispatcher = recording_dispatcher(error_service_name => error_service)
				
				response = dispatcher.call(build_request(error_service_name, "RaiseError"))
				
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::INTERNAL
				
				expect(dispatcher.completions.size).to be == 1
				
				completion = dispatcher.completions.last
				expect(completion[:status]).to be == Protocol::GRPC::Status::INTERNAL
				expect(completion[:error]).to be_a(RuntimeError)
			end
			
			it "ignores errors raised by the completion hook" do
				dispatcher = recording_dispatcher(service_name => service) do
					def emit_completion(call, status:, error: nil)
						raise "completion failed"
					end
				end
				
				response = dispatcher.call(request)
				consume_response(response)
				
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::OK
			end
		end
		
		with "#status_for" do
			it "maps application errors onto the reported status" do
				error_service_name = "test.CustomErrorService"
				error_service = raising_service(error_service_name, KeyError.new("missing"))
				
				dispatcher = recording_dispatcher(error_service_name => error_service) do
					def status_for(error)
						return Protocol::GRPC::Status::NOT_FOUND, error.message if error.is_a?(KeyError)
						
						super
					end
				end
				
				response = dispatcher.call(build_request(error_service_name, "RaiseError"))
				
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::NOT_FOUND
				expect(dispatcher.completions.last[:status]).to be == Protocol::GRPC::Status::NOT_FOUND
			end
		end
		
		with "trailer behaviour when response has data frames" do
			# When a handler writes data frames, grpc-status must be sent as a trailer (not a header).
			# Without trailer! before assign_status!, the status could end up in the wrong place.
			it "marks headers as trailers for unary response with data" do
				response = dispatcher.call(request)
				
				# Consume the response body so we can verify the full response structure
				consume_response(response)
				
				expect(response.headers).to be(:trailer?)
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::OK
			end
			
			it "marks headers as trailers for server streaming response with data" do
				response = dispatcher.call(build_request(service_name, "ServerStreamingCall"))
				
				# Consume all streamed messages
				consume_response(response)
				
				expect(response.headers).to be(:trailer?)
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::OK
			end
			
			it "marks headers as trailers when handler explicitly sets status with data" do
				error_service_name = "test.ErrorWithDataService"
				error_interface = Class.new(Protocol::GRPC::Interface) do
					rpc :WriteThenError, request_class: Protocol::GRPC::Fixtures::TestMessage,
						response_class: Protocol::GRPC::Fixtures::TestMessage, streaming: :unary
				end
				error_service = Class.new(Async::GRPC::Service) do
					define_method(:write_then_error) do |input, output, call|
						request = input.read
						output.write(Protocol::GRPC::Fixtures::TestMessage.new(value: "partial: #{request.value}"))
						Protocol::GRPC::Metadata.assign_status!(call.response.headers, status: Protocol::GRPC::Status::INTERNAL, message: "Error after data")
					end
				end.new(error_interface, error_service_name)
				dispatcher = subject.new(services: {error_service_name => error_service})
				
				response = dispatcher.call(build_request(error_service_name, "WriteThenError"))
				
				consume_response(response)
				
				expect(response.headers).to be(:trailer?)
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::INTERNAL
				expect(Protocol::GRPC::Metadata.extract_message(response.headers)).to be == "Error after data"
			end
		end
		
		with "trailers-only response (no data frames)" do
			# When a handler writes no data frames, grpc-status is sent in the header frame.
			# We do NOT call trailer! (output.count == 0), so assign_status! adds to headers.
			it "sends grpc-status in headers when handler sets status without writing data" do
				trailers_only_service_name = "test.TrailersOnlyService"
				trailers_only_interface = Class.new(Protocol::GRPC::Interface) do
					rpc :ErrorOnly, request_class: Protocol::GRPC::Fixtures::TestMessage,
						response_class: Protocol::GRPC::Fixtures::TestMessage, streaming: :unary
				end
				trailers_only_service = Class.new(Async::GRPC::Service) do
					define_method(:error_only) do |input, output, call|
						input.read
						Protocol::GRPC::Metadata.assign_status!(call.response.headers, status: Protocol::GRPC::Status::NOT_FOUND, message: "Not found")
					end
				end.new(trailers_only_interface, trailers_only_service_name)
				dispatcher = subject.new(services: {trailers_only_service_name => trailers_only_service})
				
				response = dispatcher.call(build_request(trailers_only_service_name, "ErrorOnly"))
				
				# No data to consume; grpc-status is in the header frame
				expect(response.headers).not.to be(:trailer?)
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::NOT_FOUND
				expect(Protocol::GRPC::Metadata.extract_message(response.headers)).to be == "Not found"
			end
		end
	end
end
