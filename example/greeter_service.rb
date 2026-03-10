# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async/grpc/service"
require_relative "greeter_interface"
require_relative "my_service_pb"

# Service implementation for all 4 gRPC call types.
class GreeterService < Async::GRPC::Service
	def say_hello(input, output, _call)
		request = input.read
		output.write(MyService::HelloReply.new(message: "Hello, #{request.name}!"))
	end
	
	def stream_numbers(input, output, _call)
		request = input.read
		3.times do |i|
			output.write(MyService::HelloReply.new(message: "Response #{i}: #{request.name}"))
		end
	end
	
	def collect_names(input, output, _call)
		names = []
		input.each do |request|
			names << request.name
		end
		output.write(MyService::HelloReply.new(message: "Received: #{names.join(', ')}"))
	end
	
	def chat(input, output, _call)
		input.each do |request|
			output.write(MyService::HelloReply.new(message: "Echo: #{request.name}"))
		end
		output.close_write
	end
end
