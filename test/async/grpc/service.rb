# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "async/grpc/service"
require "async/grpc/test_interface"

describe Async::GRPC::Service do
	let(:interface_class) {Async::GRPC::Fixtures::TestInterface}
	let(:service_name) {"test.Service"}
	let(:service) {Async::GRPC::Fixtures::TestService.new(interface_class, service_name)}
	
	it "has interface class" do
		expect(service.interface_class).to be == interface_class
	end
	
	it "has service name" do
		expect(service.service_name).to be == service_name
	end
	
	with "#rpc_descriptions" do
		it "converts snake_case to CamelCase" do
			descriptions = service.rpc_descriptions
			expect(descriptions.key?("UnaryCall")).to be == true
			expect(descriptions["UnaryCall"].method).to be == :unary_call
		end
		
		it "converts PascalCase to snake_case for Ruby method names" do
			descriptions = service.rpc_descriptions
			expect(descriptions.key?("SayHello")).to be == true
			expect(descriptions["SayHello"].method).to be == :say_hello  # PascalCase key maps to snake_case method
		end
		
		it "includes request and response classes" do
			descriptions = service.rpc_descriptions
			rpc_desc = descriptions["UnaryCall"]
			expect(rpc_desc.request_class).to be == Protocol::GRPC::Fixtures::TestMessage
			expect(rpc_desc.response_class).to be == Protocol::GRPC::Fixtures::TestMessage
			expect(rpc_desc.streaming).to be == :unary
		end
		
		it "uses explicit method name when provided" do
			# Create a test interface with explicit method name
			interface_with_explicit = Class.new(Protocol::GRPC::Interface) do
				rpc :XMLParser, request_class: Protocol::GRPC::Fixtures::TestMessage,
					response_class: Protocol::GRPC::Fixtures::TestMessage,
					streaming: :unary,
					method: :xml_parser  # Explicit method name
			end
			
			service_with_explicit = Async::GRPC::Service.new(interface_with_explicit, "test.Service")
			descriptions = service_with_explicit.rpc_descriptions
			
			expect(descriptions["XMLParser"].method).to be == :xml_parser
		end
	end
end
