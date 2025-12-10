# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "async/grpc/stub"
require "async/grpc/client"
require "async/http/endpoint"
require "async/grpc/test_interface"

describe Async::GRPC::Stub do
	let(:endpoint) {Async::HTTP::Endpoint.parse("http://localhost:0")}
	let(:http_client) {Async::HTTP::Client.new(endpoint)}
	let(:client) {Async::GRPC::Client.new(http_client)}
	let(:interface_class) {Async::GRPC::Fixtures::TestInterface}
	let(:service_name) {"test.Service"}
	let(:interface) {interface_class.new(service_name)}
	let(:stub) {subject.new(client, interface)}
	
	it "has interface instance" do
		expect(stub.interface).to be == interface
		expect(stub.interface.name).to be == service_name
	end
	
	with "#respond_to?" do
		it "responds to RPC methods in snake_case" do
			expect(stub.respond_to?(:unary_call)).to be == true
			expect(stub.respond_to?(:server_streaming_call)).to be == true
			expect(stub.respond_to?(:say_hello)).to be == true
		end
		
		it "does not respond to unknown methods" do
			expect(stub.respond_to?(:unknown_method)).to be == false
		end
	end
	
	with "#method_missing" do
		it "delegates to client.invoke" do
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
			
			# Mock the client.invoke method
			invoke_called = false
			invoke_args = nil
			
			mock(client) do |mock|
				mock.wrap(:invoke) do |_original, service, method, req, **options|
					invoke_called = true
					invoke_args = [service, method, req, options]
					Protocol::GRPC::Fixtures::TestMessage.new(value: "response")
				end
			end
			
			stub.unary_call(request)
			
			expect(invoke_called).to be == true
			expect(invoke_args[1]).to be == :UnaryCall  # Stub converts snake_case to PascalCase
			expect(invoke_args[2]).to be == request
		end
		
		it "extracts metadata from options" do
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
			
			invoke_options = nil
			mock(client) do |mock|
				mock.wrap(:invoke) do |_original, _service, _method, _req, **options|
					invoke_options = options
					Protocol::GRPC::Fixtures::TestMessage.new(value: "response")
				end
			end
			
			stub.unary_call(request, metadata: { "key" => "value" }, timeout: 5.0, encoding: "gzip")
			
			expect(invoke_options[:metadata]).to be == { "key" => "value" }
			expect(invoke_options[:timeout]).to be == 5.0
			expect(invoke_options[:encoding]).to be == "gzip"
		end
	end
end
