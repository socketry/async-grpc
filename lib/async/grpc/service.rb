# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "protocol/grpc/interface"

module Async
	module GRPC
		# Represents a concrete service implementation that uses an Interface.
		# Subclass this and implement the RPC methods defined in the interface.
		# Services are registered with Dispatcher for routing.
		#
		# @example Example service implementation:
		#   class GreeterInterface < Protocol::GRPC::Interface
		#     rpc :SayHello, request_class: Hello::HelloRequest, response_class: Hello::HelloReply
		#     # Optional: explicit method name for edge cases
		#     rpc :XMLParser, request_class: Hello::ParseRequest, response_class: Hello::ParseReply,
		#         method: :xml_parser  # Explicit method name (otherwise would be :xmlparser)
		#   end
		#
		#   class GreeterService < Async::GRPC::Service
		#     def say_hello(input, output, call)
		#       request = input.read
		#       reply = Hello::HelloReply.new(message: "Hello, #{request.name}!")
		#       output.write(reply)
		#     end
		#
		#     def xml_parser(input, output, call)
		#       # Implementation using explicit method name
		#     end
		#   end
		#
		#   # Register with dispatcher:
		#   dispatcher = Dispatcher.new
		#   dispatcher.register(GreeterService.new(GreeterInterface, "hello.Greeter"))
		#   server = Async::HTTP::Server.for(endpoint, dispatcher)
		class Service
			# Initialize a new service instance.
			# @parameter interface_class [Class] The interface class (subclass of Protocol::GRPC::Interface)
			# @parameter service_name [String] The service name (e.g., "hello.Greeter")
			def initialize(interface_class, service_name)
				@interface_class = interface_class
				@service_name = service_name
			end
			
			# @attribute [Class] The interface class.
			attr_reader :interface_class
			
			# @attribute [String] The service name.
			attr_reader :service_name
			
			# Get RPC descriptions from the interface class.
			# Converts Interface RPC definitions (PascalCase) to rpc_descriptions format.
			# Maps gRPC method names (PascalCase) to Ruby method names (snake_case).
			# @returns [Hash] RPC descriptions hash keyed by PascalCase method name
			def rpc_descriptions
				descriptions = {}
				
				@interface_class.rpcs.each do |pascal_case_name, rpc|
					# rpc.method is always set (either explicitly or auto-converted in Interface.rpc)
					descriptions[pascal_case_name.to_s] = rpc
				end
				
				descriptions
			end
		end
	end
end
