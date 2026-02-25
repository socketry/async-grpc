# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async"
require "async/http/client"
require "async/http/endpoint"
require "protocol/http"
require "protocol/grpc"
require_relative "../stub"
require_relative "context"
require_relative "load_balancer"

module Async
	module GRPC
		module XDS
			# Wrapper client for xDS-enabled gRPC connections
			# Follows the same pattern as Async::Redis::SentinelClient and ClusterClient
			class Client < Protocol::HTTP::Middleware
				# Raised when xDS configuration cannot be loaded
				ConfigurationError = Context::ConfigurationError
				
				# Raised when no endpoints are available
				class NoEndpointsError < StandardError
				end
				
				# Raised when cluster configuration cannot be reloaded
				ReloadError = Context::ReloadError
				
				# Create a new xDS client
				# @parameter service_name [String] Target service name (e.g., "myservice")
				# @parameter bootstrap [Hash, String, nil] Bootstrap config (hash, file path, or nil for default)
				# @parameter headers [Protocol::HTTP::Headers] Default headers
				# @parameter options [Hash] Additional options passed to underlying clients
				def initialize(service_name, bootstrap: nil, headers: Protocol::HTTP::Headers.new, node: nil, **options)
					@service_name = service_name
					@bootstrap = load_bootstrap(bootstrap)
					@headers = headers
					@options = options
					
					@context = Context.new(@bootstrap, node: node)
					@load_balancer = nil
					@clients = {}  # Cache clients per endpoint (like ClusterClient caches node.client)
					@mutex = Mutex.new
				end
				
				# Resolve endpoints lazily (like SentinelClient.resolve_address)
				# @returns [Array<Async::HTTP::Endpoint>] Available endpoints
				def resolve_endpoints
					@mutex.synchronize do
						unless @load_balancer
							# Discover cluster via CDS
							cluster = @context.discover_cluster(@service_name)
							
							# Discover endpoints via EDS
							endpoints = @context.discover_endpoints(cluster)
							
							raise NoEndpointsError, "No endpoints discovered for #{@service_name}" if endpoints.empty?
							
							# Create load balancer
							@load_balancer = LoadBalancer.new(cluster, endpoints)
							
							# Set load balancer reference in context for endpoint updates
							@context.load_balancer = @load_balancer
						end
						
						@load_balancer.healthy_endpoints
					end
				rescue Context::ReloadError => error
					raise NoEndpointsError, "No endpoints discovered for #{@service_name}", cause: error
				end
				
				# Get a client for making calls (like ClusterClient.client_for)
				# Resolves endpoints lazily and picks one via load balancer
				# @returns [Array(Async::GRPC::Client, Async::HTTP::Endpoint)] Client and endpoint for request tracking
				def client_for_call
					endpoints = resolve_endpoints
					raise NoEndpointsError, "No endpoints available for #{@service_name}" if endpoints.empty?
					
					# Pick endpoint via load balancer
					endpoint = @load_balancer.pick
					raise NoEndpointsError, "No healthy endpoints available" unless endpoint
					
					# Cache client per endpoint (like ClusterClient caches node.client)
					client = @clients[endpoint] ||= begin
						http_client = Async::HTTP::Client.new(endpoint, **@options)
						Async::GRPC::Client.new(http_client, headers: @headers)
					end
					[client, endpoint]
				end
				
				# Implement Protocol::HTTP::Middleware interface
				# This allows XDS::Client to be used anywhere Async::GRPC::Client is used
				# @parameter request [Protocol::HTTP::Request] The HTTP request
				# @returns [Protocol::HTTP::Response] The HTTP response
				def call(request, attempts: 3)
					client, endpoint = client_for_call
					@load_balancer.record_request_start(endpoint)
					begin
						client.call(request)
					rescue Protocol::GRPC::Error => error
						# Handle endpoint changes (like ClusterClient handles MOVED/ASK)
						if error.status_code == Protocol::GRPC::Status::UNAVAILABLE
							Console.warn(self, error)
							
							# Invalidate cache, reload configuration
							invalidate_cache!
							
							attempts -= 1
							retry if attempts > 0
						end
						
						raise
					rescue => error
						# Network errors might indicate endpoint failure
						Console.warn(self, error)
						
						# Invalidate this specific endpoint
						invalidate_endpoint(client)
						
						attempts -= 1
						retry if attempts > 0
						
						raise
					end
				ensure
					@load_balancer&.record_request_end(endpoint)
				end
				
				# Create a stub for the given interface.
				# Same API as Async::GRPC::Client - load balancing happens per RPC call.
				# @parameter interface_class [Class] Interface class (subclass of Protocol::GRPC::Interface)
				# @parameter service_name [String] Service name (e.g., "hello.Greeter")
				# @returns [Async::GRPC::Stub] Stub object with methods for each RPC
				def stub(interface_class, service_name)
					interface = interface_class.new(service_name)
					Stub.new(self, interface)
				end
				
				# Invoke an RPC (called by Stub). Load balances per call.
				# @parameter service [Protocol::GRPC::Interface] Interface instance
				# @parameter method [Symbol, String] Method name
				# @parameter request [Object | Nil] Request message
				# @parameter metadata [Hash] Custom metadata headers
				# @parameter timeout [Numeric | Nil] Optional timeout in seconds
				# @parameter encoding [String | Nil] Optional compression encoding
				# @parameter initial [Object | Array] Optional initial message(s) for bidirectional streaming
				# @yields {|input, output| ...} Block for streaming calls
				# @returns [Object | Protocol::GRPC::Body::ReadableBody] Response message or readable body
				def invoke(service, method, request = nil, metadata: {}, timeout: nil, encoding: nil, initial: nil, attempts: 3, &block)
					client, endpoint = client_for_call
					@load_balancer.record_request_start(endpoint)
					begin
						client.invoke(service, method, request, metadata: metadata, timeout: timeout, encoding: encoding, initial: initial, &block)
					rescue Protocol::GRPC::Error => error
						if error.status_code == Protocol::GRPC::Status::UNAVAILABLE
							Console.warn(self, error)
							invalidate_cache!
							attempts -= 1
							retry if attempts > 0
						end
						raise
					rescue => error
						Console.warn(self, error)
						invalidate_endpoint(client)
						attempts -= 1
						retry if attempts > 0
						raise
					end
				ensure
					@load_balancer&.record_request_end(endpoint)
				end
				
				# Close xDS client and all connections
				def close
					@clients.each_value(&:close)
					@clients.clear
					@context.close
					@load_balancer&.close
				end
				
			private
				
				def load_bootstrap(bootstrap)
					case bootstrap
					when Hash
						bootstrap
					when String
						load_bootstrap_file(bootstrap)
					when nil
						load_default_bootstrap
					else
						raise ArgumentError, "Invalid bootstrap: #{bootstrap.inspect}"
					end
				end
				
				def load_bootstrap_file(path)
					raise ConfigurationError, "Bootstrap file not found: #{path}" unless File.exist?(path)
					
					require "json"
					JSON.parse(File.read(path), symbolize_names: true)
				rescue JSON::ParserError => error
					raise ConfigurationError, "Invalid bootstrap JSON: #{error.message}"
				end
				
				def load_default_bootstrap
					# Try environment variable first
					if path = ENV["GRPC_XDS_BOOTSTRAP"]
						return load_bootstrap_file(path)
					end
					
					# Try default location
					default_path = File.expand_path("~/.config/grpc/bootstrap.json")
					if File.exist?(default_path)
						return load_bootstrap_file(default_path)
					end
					
					raise ConfigurationError, "No bootstrap configuration found"
				end
				
				def invalidate_cache!
					@mutex.synchronize do
						@clients.each_value(&:close)
						@clients.clear
						@load_balancer = nil
					end
				end
				
				def invalidate_endpoint(client)
					@mutex.synchronize do
						endpoint = @clients.key(client)
						@load_balancer&.mark_unhealthy(endpoint) if endpoint
						@clients.delete_if{|_, cached_client| cached_client == client}
						client.close
					end
				end
			end
		end
	end
end
