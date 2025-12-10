# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2024-2025, by Samuel Williams.

require "async/grpc"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "protocol/grpc/methods"
require "protocol/grpc/body/readable_body"
require "sus/fixtures/async/http"
require "async/grpc/test_interface"

describe Async::GRPC::Client do
	include Sus::Fixtures::Async::HTTP::ServerContext
	let(:protocol) {Async::HTTP::Protocol::HTTP2}
	
	let(:service_name) {"test.Service"}
	let(:service) {Async::GRPC::Fixtures::TestService.new(Async::GRPC::Fixtures::TestInterface, service_name)}
	let(:dispatcher) {Async::GRPC::DispatcherMiddleware.new(services: { service_name => service })}
	let(:app) {dispatcher}
	
	it "can make unary RPC call" do
		grpc_client = Async::GRPC::Client.new(client)
		stub = grpc_client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "integration test")
		response = stub.unary_call(request)
		
		expect(response).to be_a(Protocol::GRPC::Fixtures::TestMessage)
		expect(response.value).to be == "Response: integration test"
	end
	
	it "can make RPC call with snake_case method name" do
		grpc_client = Async::GRPC::Client.new(client)
		stub = grpc_client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "world")
		response = stub.say_hello(request)
		
		expect(response).to be_a(Protocol::GRPC::Fixtures::TestMessage)
		expect(response.value).to be == "Hello, world!"
	end
	
	it "can make server streaming RPC call" do
		grpc_client = Async::GRPC::Client.new(client)
		stub = grpc_client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "stream")
		
		responses = []
		stub.server_streaming_call(request) do |response|
			responses << response
		end
		
		expect(responses.length).to be == 3
		expect(responses[0].value).to be == "Response 0: stream"
		expect(responses[1].value).to be == "Response 1: stream"
		expect(responses[2].value).to be == "Response 2: stream"
	end
	
	it "handles metadata" do
		grpc_client = Async::GRPC::Client.new(client)
		stub = grpc_client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
		response = stub.unary_call(request, metadata: { "custom-header" => "custom-value" })
		
		expect(response).to be_a(Protocol::GRPC::Fixtures::TestMessage)
	end
	
	it "handles errors correctly" do
		grpc_client = Async::GRPC::Client.new(client)
		stub = grpc_client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		
		# Try to call unknown method
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
		
		expect do
			stub.unknown_method(request)
		end.to raise_exception(NoMethodError)
	end
end
