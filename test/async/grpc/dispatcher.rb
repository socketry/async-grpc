# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "sus/fixtures/async/scheduler_context"

require "async/grpc/dispatcher"
require "async/grpc/service"
require "protocol/http"
require "protocol/grpc/methods"
require "protocol/grpc/metadata"
require "protocol/grpc/body/writable_body"
require "async/grpc/test_interface"

describe Async::GRPC::Dispatcher do
	include Sus::Fixtures::Async::SchedulerContext
	
	let(:service_name) {"test.Service"}
	let(:service) {Async::GRPC::Fixtures::TestService.new(Async::GRPC::Fixtures::TestInterface, service_name)}
	let(:dispatcher) {subject.new(services: {service_name => service})}
	
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
		
		let(:headers) {Protocol::GRPC::Methods.build_headers}
		let(:path) {Protocol::GRPC::Methods.build_path(service_name, "UnaryCall")}
		let(:request) {Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)}
		
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
			path = Protocol::GRPC::Methods.build_path(service_name, "SayHello")
			request = Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)
			
			response = dispatcher.call(request)
			expect(response.status).to be == 200
			
			response_body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: Protocol::GRPC::Fixtures::TestMessage)
			
			response_message = response_body.read
			expect(response_message).not.to be_nil
			expect(response_message.value).to be == "Hello, test!"
		end
		
		it "returns UNIMPLEMENTED for unknown service" do
			path = Protocol::GRPC::Methods.build_path("unknown.Service", "UnaryCall")
			request = Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)
			
			response = dispatcher.call(request)
			expect(response.status).to be == 200 # gRPC uses trailers for errors
			
			status = Protocol::GRPC::Metadata.extract_status(response.headers)
			expect(status).to be == Protocol::GRPC::Status::UNIMPLEMENTED
		end
		
		it "returns UNIMPLEMENTED for unknown method" do
			path = Protocol::GRPC::Methods.build_path(service_name, "UnknownMethod")
			request = Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)
			
			response = dispatcher.call(request)
			status = Protocol::GRPC::Metadata.extract_status(response.headers)
			expect(status).to be == Protocol::GRPC::Status::UNIMPLEMENTED
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
			path = Protocol::GRPC::Methods.build_path(service_name, "SlowCall")
			request = Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)
			request.headers["grpc-timeout"] = "100m" # 100 milliseconds
			
			response = dispatcher.call(request)
			
			expect(response.status).to be == 200
			
			# The response body should be consumed to access trailers:
			response_body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: Protocol::GRPC::Fixtures::TestMessage)
			response_body.finish
			
			# Check that grpc-status is DEADLINE_EXCEEDED (4):
			status = Protocol::GRPC::Metadata.extract_status(response.headers)
			expect(status).to be == Protocol::GRPC::Status::DEADLINE_EXCEEDED
			
			message = Protocol::GRPC::Metadata.extract_message(response.headers)
			expect(message).to be == "Deadline exceeded!"
		end
		
		with "trailer behaviour when response has data frames" do
			# When a handler writes data frames, grpc-status must be sent as a trailer (not a header).
			# Without trailer! before assign_status!, the status could end up in the wrong place.
			# See dispatcher.rb:58-60.
			it "marks headers as trailers for unary response with data" do
				response = dispatcher.call(request)
				
				# Consume the response body so we can verify the full response structure
				response_body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: Protocol::GRPC::Fixtures::TestMessage)
				response_body.read
				response_body.finish
				
				expect(response.headers).to be(:trailer?)
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::OK
			end
			
			it "marks headers as trailers for server streaming response with data" do
				path = Protocol::GRPC::Methods.build_path(service_name, "ServerStreamingCall")
				request = Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)
				
				response = dispatcher.call(request)
				
				# Consume all streamed messages
				response_body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: Protocol::GRPC::Fixtures::TestMessage)
				response_body.each{|_|}
				response_body.finish
				
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
				
				path = Protocol::GRPC::Methods.build_path(error_service_name, "WriteThenError")
				request = Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)
				
				response = dispatcher.call(request)
				
				response_body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: Protocol::GRPC::Fixtures::TestMessage)
				response_body.read
				response_body.finish
				
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
				
				path = Protocol::GRPC::Methods.build_path(trailers_only_service_name, "ErrorOnly")
				request = Protocol::HTTP::Request.new("http", "localhost", "POST", path, nil, headers, request_body)
				
				response = dispatcher.call(request)
				
				# No data to consume; grpc-status is in the header frame
				expect(response.headers).not.to be(:trailer?)
				expect(Protocol::GRPC::Metadata.extract_status(response.headers)).to be == Protocol::GRPC::Status::NOT_FOUND
				expect(Protocol::GRPC::Metadata.extract_message(response.headers)).to be == "Not found"
			end
		end
	end
end
