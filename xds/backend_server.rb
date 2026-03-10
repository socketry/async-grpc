#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple gRPC backend server for xDS testing
# This mimics a real gRPC service that would be discovered via xDS

require "async"
require "async/http/server"
require "async/http/endpoint"
require "async/grpc/dispatcher"
require "async/grpc/service"
require_relative "../fixtures/async/grpc/test_interface"

class TestBackendService < Async::GRPC::Service
	def initialize(interface_class, service_name, backend_id)
		super(interface_class, service_name)
		@backend_id = backend_id
	end
	
	def unary_call(input, output, call)
		request = input.read
		
		# Include backend ID in response metadata (trailers)
		call.response.headers["backend-id"] = @backend_id
		
		response = Protocol::GRPC::Fixtures::TestMessage.new(
			value: "Response from #{@backend_id}: #{request&.value || 'no value'}"
		)
		
		output.write(response)
	end
	
	def say_hello(input, output, call)
		request = input.read
		
		call.response.headers["backend-id"] = @backend_id
		
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
	# Create gRPC dispatcher
	dispatcher = Async::GRPC::Dispatcher.new
	service = TestBackendService.new(Async::GRPC::Fixtures::TestInterface, service_name, backend_id)
	dispatcher.register(service)
	
	# Create endpoint (http for h2c - gRPC without TLS in docker)
	endpoint = Async::HTTP::Endpoint.parse(
		"http://0.0.0.0:#{port}",
		protocol: Async::HTTP::Protocol::HTTP2
	)
	
	# Start server
	server = Async::HTTP::Server.new(dispatcher, endpoint)
	
	Console.info{"Starting backend server #{backend_id} on port #{port}"}
	
	server.run
end
