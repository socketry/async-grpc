#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple gRPC backend server for xDS testing
# This mimics a real gRPC service that would be discovered via xDS

require "async"
require "async/http/server"
require "async/http/endpoint"
require "protocol/grpc/middleware"
require_relative "../fixtures/async/grpc/test_interface"

class TestBackendService
	def initialize(backend_id)
		@backend_id = backend_id
	end
	
	def unary_call(input, output, call)
		request = input.read
		
		# Include backend ID in response metadata
		call.set_metadata("backend-id", @backend_id)
		
		response = Protocol::GRPC::Fixtures::TestMessage.new(
			value: "Response from #{@backend_id}: #{request.value}"
		)
		
		output.write(response)
	end
	
	def say_hello(input, output, call)
		request = input.read
		
		call.set_metadata("backend-id", @backend_id)
		
		response = Protocol::GRPC::Fixtures::TestMessage.new(
			value: "Hello from #{@backend_id}, #{request.value}!"
		)
		
		output.write(response)
	end
end

port = ENV["PORT"] || "50051"
backend_id = ENV["BACKEND_ID"] || "backend-unknown"
service_name = ENV["SERVICE_NAME"] || "test.Service"

Async do
	# Create gRPC middleware
	grpc = Protocol::GRPC::Middleware.new
	service = TestBackendService.new(backend_id)
	grpc.register(service_name, service)
	
	# Create endpoint
	endpoint = Async::HTTP::Endpoint.parse(
		"https://0.0.0.0:#{port}",
		protocol: Async::HTTP::Protocol::HTTP2
	)
	
	# Start server
	server = Async::HTTP::Server.new(grpc, endpoint)
	
	Console.logger.info(self){"Starting backend server #{backend_id} on port #{port}"}
	
	server.run
end
