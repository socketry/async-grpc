# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async"
require "async/http/client"
require "async/http/endpoint"
require "async/grpc/client"
require "async/grpc/xds/ads_stream"
require "securerandom"
require "envoy/service/discovery/v3/aggregated_discovery_service"
require "envoy/service/discovery/v3/discovery_pb"
require "envoy/config/core/v3/base_pb"
require "envoy/config/cluster/v3/cluster_pb"
require "envoy/config/endpoint/v3/endpoint_pb"
require "google/protobuf/any_pb"

module Async
	module GRPC
		module XDS
			# Client for xDS APIs (ADS or individual APIs)
			# Implements Aggregated Discovery Service (ADS) protocol
			# Acts as delegate for ADSStream, receiving discovery_response events
			class DiscoveryClient
				include ADSStream::Delegate
				# xDS API type URLs (v3 API)
				LISTENER_TYPE = "type.googleapis.com/envoy.config.listener.v3.Listener"
				ROUTE_TYPE = "type.googleapis.com/envoy.config.route.v3.RouteConfiguration"
				CLUSTER_TYPE = "type.googleapis.com/envoy.config.cluster.v3.Cluster"
				ENDPOINT_TYPE = "type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment"
				SECRET_TYPE = "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"
				
				# Initialize xDS discovery client
				# @parameter server_config [Hash] xDS server configuration from bootstrap
				# @parameter node [Hash] Node information (id, cluster, metadata, locality)
				def initialize(server_config, node: nil)
					@server_uri = server_config[:server_uri]
					@channel_creds = server_config[:channel_creds]
					@server_features = server_config[:server_features] || []
					@node_info = node || build_node_info
					@node = build_node_proto(@node_info)
					@grpc_client = nil
					@versions = {}  # Track version_info per type_url
					@nonces = {}     # Track nonces per type_url
					@mutex = Mutex.new
					@subscriptions = {}  # Track subscriptions by type_url
					@stream_task = nil
					@ads_stream = nil  # ADSStream instance when connected (owns stream state)
					@stream_ready_promise = nil  # Resolved when stream_opened runs
				end
				
				# Subscribe to resource type using ADS
				# (Aggregated Discovery Service - single stream for all types)
				# @parameter type_url [String] Resource type URL
				# @parameter resource_names [Array<String>] Resources to subscribe to
				# @yields [Array] Updated resources (as protobuf objects)
				# @returns [Async::Task] Subscription task
				def subscribe(type_url, resource_names, &block)
					# Store subscription callback
					@mutex.synchronize do
						@subscriptions[type_url] = {
							resource_names: resource_names,
							callback: block
						}
					end
					
					# Ensure ADS stream is running
					ensure_stream_running
					
					# Wait for stream to be ready (event-driven, no polling)
					promise = @stream_ready_promise
					if promise && !promise.completed?
						begin
							promise.wait(timeout: 5)
						rescue Async::TimeoutError
							# Stream didn't open in time; send_discovery_request will no-op if @ads_stream is nil
						end
					end
					
					send_discovery_request(type_url, resource_names) if @ads_stream
					
					# Return the stream task (already running)
					@stream_task
				end
				
				# Close xDS discovery client
				def close
					@mutex.synchronize do
						@stream_task&.stop
						@grpc_client&.close
						@grpc_client = nil
						@subscriptions.clear
						@stream_task = nil
						@ads_stream = nil
						@stream_ready_promise = nil
					end
				end
				
			private
				
				def ensure_stream_running
					@mutex.synchronize do
						return if @stream_task&.running?
						
						@stream_ready_promise = Async::Promise.new
						@stream_task = Async do |task|
							backoff = 5
							loop do
								begin
									create_and_run_ads_stream(task)
									break
								rescue Async::Stop
									raise
								rescue => error
									Console.error(self, error)
									
									@mutex.synchronize do
										@grpc_client&.close
										@grpc_client = nil
										@ads_stream = nil
										@stream_ready_promise = Async::Promise.new
									end
									
									sleep(backoff)
									backoff = [backoff * 2, 60].min
								end
							end
						end
					end
				end
				
				def create_and_run_ads_stream(task)
					# Create gRPC client
					server_uri = @server_uri
					unless server_uri.match?(/^https?:\/\//)
						use_insecure = @channel_creds&.any?{|cred| cred[:type] == "insecure"}
						scheme = use_insecure ? "http" : "https"
						server_uri = "#{scheme}://#{server_uri}"
					end
					Console.debug(self, "Connecting to xDS server:", server_uri: server_uri)
					endpoint = Async::HTTP::Endpoint.parse(server_uri, protocol: Async::HTTP::Protocol::HTTP2)
					http_client = Async::HTTP::Client.new(endpoint)
					grpc_client = Async::GRPC::Client.new(http_client)
					
					@mutex.synchronize{@grpc_client = grpc_client}
					
					# ADSStream owns the stream; we act as delegate receiving discovery_response events
					ads_stream = ADSStream.new(grpc_client, @node, delegate: self)
					ads_stream.run(initial: build_initial_requests)
				end
				
			# ADSStream::Delegate interface - must be public for ADSStream to call
			public
				
				def stream_opened(stream)
					@mutex.synchronize{@ads_stream = stream}
					@stream_ready_promise&.resolve(stream)
				end
				
				def stream_closed(stream)
					@mutex.synchronize{@ads_stream = nil}
				end
				
				def discovery_response(response, stream)
					process_response(response, stream)
				end
				
			private
				
				def send_discovery_request(type_url, resource_names)
					@mutex.synchronize do
						stream = @ads_stream
						return unless stream
						
						request = Envoy::Service::Discovery::V3::DiscoveryRequest.new(
							version_info: @versions[type_url] || "",
							node: @node,
							resource_names: resource_names,
							type_url: type_url,
							response_nonce: @nonces[type_url] || ""
						)
						stream.send(request)
					end
				rescue => error
					Console.error(self, error)
					raise
				end
				
				def build_initial_requests
					# Build discovery requests for all active subscriptions.
					# If no subscriptions exist, return minimal request with node info so the server
					# receives data and responds (avoids deadlock when server waits for first message).
					subscriptions_copy = nil
					@mutex.synchronize do
						subscriptions_copy = @subscriptions.dup
					end
					
					if subscriptions_copy.empty?
						Console.info(self){"Building initial DiscoveryRequest (no subscriptions yet)"}
						[Envoy::Service::Discovery::V3::DiscoveryRequest.new(node: @node)]
					else
						Console.info(self){"Building #{subscriptions_copy.size} subscription requests"}
						subscriptions_copy.map do |type_url, subscription|
							Envoy::Service::Discovery::V3::DiscoveryRequest.new(
								version_info: @versions[type_url] || "",
								node: @node,
								resource_names: subscription[:resource_names],
								type_url: type_url,
								response_nonce: @nonces[type_url] || ""
							)
						end
					end
				end
				
				def process_response(response, stream)
					type_url = response.type_url
					Console.debug(self, "Processing response:", type_url: type_url)
					
					callback = nil
					resources = nil
					resource_names = nil
					
					@mutex.synchronize do
						subscription = @subscriptions[type_url]
						unless subscription
							Console.warn(self){"No subscription found!", type_url: type_url}
							return
						end
						
						# Update version and nonce
						@versions[type_url] = response.version_info
						@nonces[type_url] = response.nonce
						
						# Deserialize resources (skip failed; callback receives only valid resources)
						resources = response.resources.filter_map do |any_resource|
							deserialize_resource(any_resource, type_url)
						end
						
						# Capture for use outside mutex (avoid deadlock)
						callback = subscription[:callback]
						resource_names = subscription[:resource_names]
					end
					
					# Call callback outside mutex
					if callback
						callback.call(resources)
					else
						Console.warn(self, "No callback found!", type_url: type_url)
					end
					
					# Send ACK (acknowledge receipt)
					@mutex.synchronize do
						send_ack(type_url, resource_names, stream)
					end
				end
				
				def send_ack(type_url, resource_names, stream)
					request = Envoy::Service::Discovery::V3::DiscoveryRequest.new(
						version_info: @versions[type_url] || "",
						node: @node,
						resource_names: resource_names,
						type_url: type_url,
						response_nonce: @nonces[type_url] || ""
					)
					stream.send(request)
				rescue => error
					Console.warn(self, "Failed to send ACK: #{error.message}")
				end
				
				def deserialize_resource(any_resource, type_url)
					# Deserialize google.protobuf.Any to appropriate resource type
					# Based on type_url, decode the value to the correct protobuf message
					case type_url
					when CLUSTER_TYPE
						# Decode Cluster from Any.value
						begin
							cluster_proto = Envoy::Config::Cluster::V3::Cluster.decode(any_resource.value)
							Resources::Cluster.from_proto(cluster_proto)
						rescue => error
							Console.warn(self, "Failed to deserialize Cluster: #{error.message}")
							nil
						end
					when ENDPOINT_TYPE
						# Decode ClusterLoadAssignment from Any.value
						begin
							endpoint_proto = Envoy::Config::Endpoint::V3::ClusterLoadAssignment.decode(any_resource.value)
							Resources::ClusterLoadAssignment.from_proto(endpoint_proto)
						rescue => error
							Console.warn(self, "Failed to deserialize ClusterLoadAssignment: #{error.message}")
							nil
						end
					else
						# For other types, return raw protobuf for now
						any_resource
					end
				end
				
				def build_node_proto(node_info)
					# Build envoy.config.core.v3.Node protobuf
					Envoy::Config::Core::V3::Node.new(
						id: node_info[:id] || generate_node_id,
						cluster: node_info[:cluster] || ENV["XDS_CLUSTER"] || "default",
						metadata: build_metadata_struct(node_info[:metadata] || {}),
						locality: node_info[:locality] ? build_locality_proto(node_info[:locality]) : nil
					)
				end
				
				def build_metadata_struct(metadata_hash)
					# Convert hash to google.protobuf.Struct
					return nil if metadata_hash.empty?
					
					fields = {}
					metadata_hash.each do |key, value|
						fields[key.to_s] = case value
						when String
							Google::Protobuf::Value.new(string_value: value)
						when Numeric
							Google::Protobuf::Value.new(number_value: value.to_f)
						when TrueClass, FalseClass
							Google::Protobuf::Value.new(bool_value: value)
						else
							Google::Protobuf::Value.new(string_value: value.to_s)
						end
					end
					
					Google::Protobuf::Struct.new(fields: fields)
				end
				
				def build_locality_proto(locality_hash)
					# Build envoy.config.core.v3.Locality protobuf
					Envoy::Config::Core::V3::Locality.new(
						region: locality_hash[:region] || "",
						zone: locality_hash[:zone] || "",
						sub_zone: locality_hash[:sub_zone] || ""
					)
				end
				
				def build_node_info
					# Build node identification for xDS server
					# Based on envoy.config.core.v3.Node
					{
						id: generate_node_id,
						cluster: ENV["XDS_CLUSTER"] || "default",
						metadata: {},
						locality: nil
					}
				end
				
				def generate_node_id
					# Generate unique node ID
					"#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(4)}"
				end
			end
		end
	end
end
