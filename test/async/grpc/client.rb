# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async/grpc"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "protocol/grpc/methods"
require "protocol/grpc/body/readable_body"
require "sus/fixtures/async/http"
require "async/grpc/test_interface"

AClient = Sus::Shared("a client") do
	let(:service_name) {"test.Service"}
	let(:service) {Async::GRPC::Fixtures::TestService.new(Async::GRPC::Fixtures::TestInterface, service_name)}
	let(:dispatcher) {Async::GRPC::Dispatcher.new(services: { service_name => service })}
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
	
	with "error handling" do
		let(:error_service_name) {"test.ErrorService"}
		let(:error_interface_class) do
			Class.new(Protocol::GRPC::Interface) do
				rpc :ReturnError, request_class: Protocol::GRPC::Fixtures::TestMessage,
					response_class: Protocol::GRPC::Fixtures::TestMessage, streaming: :unary
			end
		end
		let(:error_service) do
			Class.new(Async::GRPC::Service) do
				define_method(:return_error) do |input, output, call|
					request = input.read
					
					# Set error status and message based on request value
					case request.value
					when "internal"
						status = Protocol::GRPC::Status::INTERNAL
						message = "Internal server error"
					when "not_found"
						status = Protocol::GRPC::Status::NOT_FOUND
						message = "Resource not found"
					when "with_backtrace"
						status = Protocol::GRPC::Status::INTERNAL
						message = "Error with backtrace"
						# Add backtrace to metadata (comma-separated string, Split header will parse into array)
						call.response.headers["backtrace"] = "/path/to/file.rb:10:in `method', /path/to/file.rb:5:in `block'"
					when "with_metadata"
						status = Protocol::GRPC::Status::INVALID_ARGUMENT
						message = "Invalid argument"
						# Add custom metadata
						call.response.headers["custom-key"] = "custom-value"
					else
						status = Protocol::GRPC::Status::UNKNOWN
						message = "Unknown error"
					end
					
					Protocol::GRPC::Metadata.add_status!(call.response.headers, status: status, message: message)
				end
			end.new(error_interface_class, error_service_name)
		end
		let(:app) {Async::GRPC::Dispatcher.new(services: { error_service_name => error_service })}
		
		it "raises Protocol::GRPC::Error with correct status code" do
			grpc_client = Async::GRPC::Client.new(client)
			stub = grpc_client.stub(error_interface_class, error_service_name)
			
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "internal")
			
			begin
				stub.return_error(request)
				expect(false).to be == true # Should not reach here
			rescue Protocol::GRPC::Internal => error
				expect(error.status_code).to be == Protocol::GRPC::Status::INTERNAL
				# Message comes from RemoteError (cause), not the Protocol::GRPC::Error itself
				expect(error.cause.message).to be == "Internal server error"
			end
		end
		
		it "raises correct error class for status code" do
			grpc_client = Async::GRPC::Client.new(client)
			stub = grpc_client.stub(error_interface_class, error_service_name)
			
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "not_found")
			
			begin
				stub.return_error(request)
				expect(false).to be == true # Should not reach here
			rescue Protocol::GRPC::NotFound => error
				expect(error.status_code).to be == Protocol::GRPC::Status::NOT_FOUND
				expect(error.cause.message).to be == "Resource not found"
			end
		end
		
		it "extracts and sets backtrace from metadata on RemoteError" do
			grpc_client = Async::GRPC::Client.new(client)
			stub = grpc_client.stub(error_interface_class, error_service_name)
			
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "with_backtrace")
			
			begin
				stub.return_error(request)
				expect(false).to be == true # Should not reach here
			rescue Protocol::GRPC::Internal => error
				expect(error.cause).to be_a(Async::GRPC::RemoteError)
				expect(error.cause.message).to be == "Error with backtrace"
				# Backtrace comes as array from Split header format
				backtrace = error.cause.backtrace
				expect(backtrace).to be_a(Array)
				# Split header splits comma-separated string into array
				expect(backtrace.length).to be >= 1
				expect(backtrace.any?{|line| line.include?("file.rb:10")}).to be == true
				expect(backtrace.any?{|line| line.include?("file.rb:5")}).to be == true
			end
		end
		
		it "preserves metadata in error" do
			grpc_client = Async::GRPC::Client.new(client)
			stub = grpc_client.stub(error_interface_class, error_service_name)
			
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "with_metadata")
			
			begin
				stub.return_error(request)
				expect(false).to be == true # Should not reach here
			rescue Protocol::GRPC::InvalidArgument => error
				expect(error.metadata.key?("custom-key")).to be == true
				expect(error.metadata["custom-key"]).to be == ["custom-value"]
			end
		end
		
		it "sets RemoteError as cause of Protocol::GRPC::Error" do
			grpc_client = Async::GRPC::Client.new(client)
			stub = grpc_client.stub(error_interface_class, error_service_name)
			
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "internal")
			
			begin
				stub.return_error(request)
				expect(false).to be == true # Should not reach here
			rescue Protocol::GRPC::Internal => error
				expect(error.cause).to be_a(Async::GRPC::RemoteError)
				expect(error.cause.message).to be == "Internal server error"
			end
		end
	end
end

describe Async::GRPC::Client do
	include Sus::Fixtures::Async::HTTP::ServerContext
	
	with "http/1" do
		let(:protocol) {Async::HTTP::Protocol::HTTP1}
		it_behaves_like AClient
	end
	
	with "http/2" do
		let(:protocol) {Async::HTTP::Protocol::HTTP2}
		it_behaves_like AClient
	end
end
