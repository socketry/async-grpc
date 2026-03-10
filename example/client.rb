#!/usr/bin/env ruby
# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async/grpc"
require "async/http/endpoint"
require_relative "greeter_interface"
require_relative "my_service_pb"

def main
	Async::GRPC::Client.open("http://localhost:50051") do |client|
		stub = client.stub(GreeterInterface, "my_service.Greeter")
		
		puts "=== Unary: SayHello ==="
		response = stub.say_hello(MyService::HelloRequest.new(name: "World"))
		puts response.message
		
		puts "\n=== Server Streaming: StreamNumbers ==="
		stub.stream_numbers(MyService::HelloRequest.new(name: "Stream")) do |reply|
			puts reply.message
		end
		
		puts "\n=== Client Streaming: CollectNames ==="
		response = stub.collect_names do |output|
			output.write(MyService::HelloRequest.new(name: "Alice"))
			output.write(MyService::HelloRequest.new(name: "Bob"))
			output.write(MyService::HelloRequest.new(name: "Carol"))
		end
		puts response.message
		
		puts "\n=== Bidirectional Streaming: Chat ==="
		stub.chat do |output, input|
			output.write(MyService::HelloRequest.new(name: "message1"))
			output.write(MyService::HelloRequest.new(name: "message2"))
			output.write(MyService::HelloRequest.new(name: "message3"))
			output.close_write
			
			input.each do |reply|
				puts reply.message
			end
		end
	end
end

main
