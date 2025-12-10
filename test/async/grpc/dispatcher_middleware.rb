# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "async/grpc/dispatcher_middleware"
require "async/grpc/service"
require "protocol/http"
require "protocol/grpc/methods"
require "protocol/grpc/body/writable_body"
require "async/grpc/test_interface"

describe Async::GRPC::DispatcherMiddleware do
	let(:service_name) {"test.Service"}
	let(:service) {Async::GRPC::Fixtures::TestService.new(Async::GRPC::Fixtures::TestInterface, service_name)}
	let(:dispatcher) {subject.new(services: { service_name => service })}
	
	with "#register" do
		it "can register a service" do
			dispatcher = subject.new
			dispatcher.register(service_name, service)
			expect(dispatcher.instance_variable_get(:@services)[service_name]).to be == service
		end
	end
	
	with "#call" do
		let(:request_body) do
			body = Protocol::GRPC::Body::WritableBody.new
			request_message = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
			body.write(request_message)
			body.close_write
			body
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
			
			response_body = Protocol::GRPC::Body::ReadableBody.new(response.body, message_class: Protocol::GRPC::Fixtures::TestMessage)
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
	end
end
