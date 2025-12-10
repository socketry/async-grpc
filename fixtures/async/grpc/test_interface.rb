# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "protocol/grpc/interface"
require_relative "test_message"

module Async
	module GRPC
		module Fixtures
			# Test interface for unit tests
			# RPC names use PascalCase to match .proto files
			class TestInterface < Protocol::GRPC::Interface
				rpc :UnaryCall, request_class: Protocol::GRPC::Fixtures::TestMessage,
					response_class: Protocol::GRPC::Fixtures::TestMessage, streaming: :unary
				rpc :ServerStreamingCall, request_class: Protocol::GRPC::Fixtures::TestMessage,
					response_class: Protocol::GRPC::Fixtures::TestMessage, streaming: :server_streaming
				rpc :SayHello, request_class: Protocol::GRPC::Fixtures::TestMessage,
					response_class: Protocol::GRPC::Fixtures::TestMessage, streaming: :unary
			end
			
			# Test service implementation
			# Method names use snake_case (Ruby convention)
			class TestService < Async::GRPC::Service
				def unary_call(input, output, _call)
					request = input.read
					response = Protocol::GRPC::Fixtures::TestMessage.new(value: "Response: #{request.value}")
					output.write(response)
				end
				
				def server_streaming_call(input, output, _call)
					request = input.read
					3.times do |i|
						response = Protocol::GRPC::Fixtures::TestMessage.new(value: "Response #{i}: #{request.value}")
						output.write(response)
					end
				end
				
				def say_hello(input, output, _call)
					request = input.read
					response = Protocol::GRPC::Fixtures::TestMessage.new(value: "Hello, #{request.value}!")
					output.write(response)
				end
			end
		end
	end
end
