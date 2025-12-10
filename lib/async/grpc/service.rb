# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "protocol/grpc/interface"

module Async
	module GRPC
		# Represents a concrete service implementation that uses an Interface.
		# Subclass this and implement the RPC methods defined in the interface.
		# Services are registered with DispatcherMiddleware for routing.
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
		#   dispatcher = DispatcherMiddleware.new
		#   dispatcher.register("hello.Greeter", GreeterService.new(GreeterInterface, "hello.Greeter"))
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
					# Use explicit method name if provided, otherwise convert PascalCase to snake_case:
					ruby_method_name = if rpc.method
						rpc.method
					else
						snake_case_name = pascal_case_to_snake_case(pascal_case_name.to_s)
						snake_case_name.to_sym
					end
					
					descriptions[pascal_case_name.to_s] = {
						method: ruby_method_name,
						request_class: rpc.request_class,
						response_class: rpc.response_class,
						streaming: rpc.streaming
					}
				end
				
				descriptions
			end
			
		private
			
			# Convert PascalCase to snake_case.
			# @parameter pascal_case [String] PascalCase string (e.g., "SayHello")
			# @returns [String] snake_case string (e.g., "say_hello")
			def pascal_case_to_snake_case(pascal_case)
				pascal_case
					.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')  # Insert underscore before capital letters followed by lowercase
					.gsub(/([a-z\d])([A-Z])/, '\1_\2')      # Insert underscore between lowercase/digit and uppercase
					.downcase
			end
		end
	end
end
