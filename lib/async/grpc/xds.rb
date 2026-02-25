# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

# Load order matters - Context must be loaded before Client
require_relative "xds/resource_cache"
require_relative "xds/resources"
require_relative "xds/ads_stream"
require_relative "xds/discovery_client"
require_relative "xds/health_checker"
require_relative "xds/load_balancer"
require_relative "xds/context"
require_relative "xds/client"

module Async
	module GRPC
		# xDS (Discovery Service) support for dynamic service discovery and configuration
		# 
		# Provides dynamic service discovery and load balancing for gRPC clients
		# using the xDS (Discovery Service) protocol.
		#
		# @example Basic usage
		#   require "async/grpc/xds"
		#   
		#   bootstrap = {
		#     "xds_servers" => [{"server_uri" => "xds-control-plane:18000"}],
		#     "node" => {"id" => "client-1", "cluster" => "test"}
		#   }
		#   
		#   xds_client = Async::GRPC::XDS::Client.new("myservice", bootstrap: bootstrap)
		#   stub = xds_client.stub(MyServiceInterface, "myservice")
		#   response = stub.say_hello(request)
		module XDS
		end
	end
end
