# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async"
require "async/grpc/client"
require "envoy/service/discovery/v3/aggregated_discovery_service"
require "envoy/service/discovery/v3/discovery_pb"
require "envoy/config/core/v3/base_pb"

module Async
	module GRPC
		module XDS
			# Encapsulates a single ADS (Aggregated Discovery Service) bidirectional stream.
			# Owns the stream lifecycle and delegates events to a delegate object.
			class ADSStream
				# Interface for ADSStream delegates. Implement these methods to receive stream events.
				module Delegate
					# Called when a DiscoveryResponse is received from the server.
					# @parameter response [Envoy::Service::Discovery::V3::DiscoveryResponse] The discovery response
					# @parameter stream [ADSStream] The stream instance; use stream.send(request) to send ACKs or new requests
					def discovery_response(response, stream)
					end
				end
				
				def initialize(client, node, delegate:)
					@client = client
					@node = node
					@delegate = delegate
					@body = nil
				end
				
				# Send a DiscoveryRequest on the stream. Call from within discovery_response to send ACKs.
				# @parameter request [Envoy::Service::Discovery::V3::DiscoveryRequest] The request to send
				def send(request)
					@body&.write(request)
				end
				
				# Run the ADS stream. Blocks until the stream completes or errors.
				# @parameter initial [Object | Array | Nil] Initial message(s) to send (defaults to node-only request if nil/empty)
				def run(initial: nil)
					service = Envoy::Service::Discovery::V3::AggregatedDiscoveryService.new(
						"envoy.service.discovery.v3.AggregatedDiscoveryService"
					)
					
					initial = Array(initial).any? ? initial : [Envoy::Service::Discovery::V3::DiscoveryRequest.new(node: @node)]
					
					@client.invoke(service, :StreamAggregatedResources, nil, initial: initial) do |body, readable_body|
						@body = body
						@delegate.stream_opened(self) if @delegate.respond_to?(:stream_opened)
						
						begin
							readable_body.each do |response|
								@delegate.discovery_response(response, self)
							end
						ensure
							@delegate.stream_closed(self) if @delegate.respond_to?(:stream_closed)
							@body = nil
						end
					end
				rescue => error
					@delegate.stream_error(self, error) if @delegate.respond_to?(:stream_error)
					Console.error(self, "Failed while streaming updates!", exception: error)
					raise
				end
			end
		end
	end
end
