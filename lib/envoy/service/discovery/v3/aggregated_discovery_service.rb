# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

# Service interface for Envoy Aggregated Discovery Service (ADS)
# This defines the RPC methods for xDS communication

require "protocol/grpc/interface"
require "envoy/service/discovery/v3/discovery_pb"

module Envoy
	module Service
		module Discovery
			module V3
				# Interface definition for AggregatedDiscoveryService
				# Used with Async::GRPC::Client to make xDS calls
				#
				# @example Using with Async::GRPC::Client
				#   require "envoy/service/discovery/v3/aggregated_discovery_service"
				#   require "async/grpc/client"
				#
				#   endpoint = Async::HTTP::Endpoint.parse("https://xds-control-plane:18000")
				#   http_client = Async::HTTP::Client.new(endpoint)
				#   grpc_client = Async::GRPC::Client.new(http_client)
				#
				#   stub = grpc_client.stub(
				#     Envoy::Service::Discovery::V3::AggregatedDiscoveryService,
				#     "envoy.service.discovery.v3.AggregatedDiscoveryService"
				#   )
				#
				#   # Bidirectional streaming RPC
				#   stub.stream_aggregated_resources do |input, output|
				#     request = Envoy::Service::Discovery::V3::DiscoveryRequest.new(
				#       type_url: "type.googleapis.com/envoy.config.cluster.v3.Cluster",
				#       resource_names: ["my-cluster"]
				#     )
				#     output.write(request)
				#
				#     input.each do |response|
				#       # Process DiscoveryResponse
				#     end
				#   end
				class AggregatedDiscoveryService < Protocol::GRPC::Interface
					# StreamAggregatedResources is a bidirectional streaming RPC
					# Request: stream of DiscoveryRequest
					# Response: stream of DiscoveryResponse
					rpc :StreamAggregatedResources,
						request_class: DiscoveryRequest,
						response_class: DiscoveryResponse,
						streaming: :bidirectional
					
					# DeltaAggregatedResources is a bidirectional streaming RPC for incremental xDS
					# Request: stream of DeltaDiscoveryRequest
					# Response: stream of DeltaDiscoveryResponse
					rpc :DeltaAggregatedResources,
						request_class: DeltaDiscoveryRequest,
						response_class: DeltaDiscoveryResponse,
						streaming: :bidirectional
				end
			end
		end
	end
end
