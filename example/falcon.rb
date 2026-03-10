#!/usr/bin/env falcon-host
# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "falcon/environment/application"
require "async/grpc/dispatcher"
require_relative "greeter_interface"
require_relative "greeter_service"

SERVICE_NAME = "my_service.Greeter"

dispatcher = Async::GRPC::Dispatcher.new
dispatcher.register(GreeterService.new(GreeterInterface, SERVICE_NAME))

service "hello.localhost" do
	include Falcon::Environment::Application
	
	middleware do
		dispatcher
	end
	
	scheme "http"
	protocol {Async::HTTP::Protocol::HTTP2}
	
	endpoint do
		Async::HTTP::Endpoint.for(scheme, "localhost", port: 50_051, protocol: protocol)
	end
end
