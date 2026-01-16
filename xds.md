# xDS Support for Async::GRPC

This document outlines the design and implementation of xDS (Discovery Service) support for `async-grpc`, enabling dynamic service discovery and configuration for gRPC clients. The design follows patterns established in `async-redis` (SentinelClient and ClusterClient) for service discovery and load balancing.

## Overview

xDS is a set of discovery APIs originally created for Envoy proxy and now adopted as a standard for dynamic configuration in gRPC and other systems. It provides a unified mechanism for service mesh control planes to configure data planes.

### What is xDS?

xDS consists of multiple discovery service APIs:

- **LDS** (Listener Discovery Service) - Defines what ports/protocols to listen on
- **RDS** (Route Discovery Service) - Defines how requests are routed
- **CDS** (Cluster Discovery Service) - Defines logical upstream services
- **EDS** (Endpoint Discovery Service) - Defines actual IP:port backends
- **SDS** (Secret Discovery Service) - Distributes certificates and keys
- **TDS** (Transport Discovery Service) - Configures transport sockets
- **ECDS** (Extension Config Discovery Service) - Distributes extension configurations

### Why xDS for gRPC?

1. **Dynamic Service Discovery** - Discover backends without hardcoded addresses
2. **Load Balancing** - Intelligent client-side load balancing with health checking
3. **Traffic Management** - Sophisticated routing, retries, timeouts
4. **Security** - Dynamic certificate distribution and mTLS configuration
5. **Observability** - Standardized metrics and tracing integration
6. **Service Mesh Integration** - Compatible with Istio, Linkerd, etc.

## Architecture

### Design Pattern: Wrapper Client (Like SentinelClient/ClusterClient)

Following the pattern from `async-redis`, xDS support is implemented as a **wrapper client** that handles discovery and load balancing, rather than modifying the base `Async::GRPC::Client` class.

**Key Principles:**
- `XDS::Client` wraps `Async::GRPC::Client` instances
- Implements `Protocol::HTTP::Middleware` interface (same as `Async::GRPC::Client`)
- Lazy endpoint resolution (resolved on first use)
- Client caching per endpoint (reuse connections)
- Error handling with cache invalidation and retry

### Component Structure

```
Async::GRPC::XDS
├── Client              # Main wrapper client (like SentinelClient)
├── Context             # Manages xDS state and subscriptions
├── DiscoveryClient     # xDS API client (ADS or individual xDS APIs)
├── ResourceCache       # Caches discovered resources
├── LoadBalancer        # Client-side load balancing
├── HealthChecker       # Endpoint health checking
└── Resources           # Resource data models
    ├── Listener
    ├── RouteConfiguration
    ├── Cluster
    ├── ClusterLoadAssignment
    └── Secret
```

## Core Components

### 1. `Async::GRPC::XDS::Client`

The main wrapper client that handles xDS discovery and load balancing. Similar to `SentinelClient` and `ClusterClient` in async-redis.

```ruby
module Async
	module GRPC
		module XDS
			# Wrapper client for xDS-enabled gRPC connections
			# Follows the same pattern as Async::Redis::SentinelClient and ClusterClient
			class Client < Protocol::HTTP::Middleware
				# Raised when xDS configuration cannot be loaded
				class ConfigurationError < StandardError
				end
				
				# Raised when no endpoints are available
				class NoEndpointsError < StandardError
				end
				
				# Raised when cluster configuration cannot be reloaded
				class ReloadError < StandardError
				end
				
				# Create a new xDS client
				# @parameter service_name [String] Target service name (e.g., "myservice")
				# @parameter bootstrap [Hash, String, nil] Bootstrap config (hash, file path, or nil for default)
				# @parameter headers [Protocol::HTTP::Headers] Default headers
				# @parameter options [Hash] Additional options passed to underlying clients
				def initialize(service_name, bootstrap: nil, headers: Protocol::HTTP::Headers.new, **options)
					@service_name = service_name
					@bootstrap = load_bootstrap(bootstrap)
					@headers = headers
					@options = options
					
					@context = Context.new(@bootstrap)
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
							
							# Create load balancer
							@load_balancer = LoadBalancer.new(@context, cluster, endpoints)
						end
						
						@load_balancer.healthy_endpoints
					end
				end
				
				# Get a client for making calls (like ClusterClient.client_for)
				# Resolves endpoints lazily and picks one via load balancer
				# @returns [Async::GRPC::Client] gRPC client for selected endpoint
				def client_for_call
					endpoints = resolve_endpoints
					raise NoEndpointsError, "No endpoints available for #{@service_name}" if endpoints.empty?
					
					# Pick endpoint via load balancer
					endpoint = @load_balancer.pick
					raise NoEndpointsError, "No healthy endpoints available" unless endpoint
					
					# Cache client per endpoint (like ClusterClient caches node.client)
					@clients[endpoint] ||= begin
						http_client = Async::HTTP::Client.new(endpoint)
						Async::GRPC::Client.new(http_client, headers: @headers)
					end
				end
				
				# Implement Protocol::HTTP::Middleware interface
				# This allows XDS::Client to be used anywhere Async::GRPC::Client is used
				# @parameter request [Protocol::HTTP::Request] The HTTP request
				# @returns [Protocol::HTTP::Response] The HTTP response
				def call(request, attempts: 3)
					# Get client for this call (load balanced)
					client = client_for_call
					
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
				end
				
				# Create a stub for the given interface
				# Delegates to underlying client (maintains Async::GRPC::Client interface)
				# @parameter interface_class [Class] Interface class (subclass of Protocol::GRPC::Interface)
				# @parameter service_name [String] Service name (e.g., "hello.Greeter")
				# @returns [Async::GRPC::Stub] Stub object with methods for each RPC
				def stub(interface_class, service_name)
					# Use a client to create stub (will be load balanced per call)
					client = client_for_call
					client.stub(interface_class, service_name)
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
					JSON.parse(File.read(path))
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
						@clients.delete_if { |endpoint, cached_client| cached_client == client }
						client.close
					end
				end
			end
		end
	end
end
```

### 2. `Async::GRPC::XDS::Context`

Manages xDS subscriptions and maintains discovered resource state. Similar to how `ClusterClient` manages cluster configuration.

```ruby
module Async
	module GRPC
		module XDS
			# Manages xDS subscriptions and maintains discovered resource state
			class Context
				# Initialize xDS context
				# @parameter bootstrap [Hash] Bootstrap configuration
				def initialize(bootstrap)
					@bootstrap = bootstrap
					@discovery_client = DiscoveryClient.new(bootstrap["xds_servers"].first)
					@cache = ResourceCache.new
					@subscriptions = {}  # Track active subscriptions
					@mutex = Mutex.new
				end
				
				# Discover cluster for service (like ClusterClient.reload_cluster!)
				# @parameter service_name [String] Service to discover
				# @returns [Resources::Cluster] Cluster configuration
				def discover_cluster(service_name)
					@mutex.synchronize do
						# Check cache first
						if cluster = @cache.get_cluster(service_name)
							return cluster
						end
						
						# Subscribe to CDS if not already subscribed
						unless @subscriptions[:cds]
							@subscriptions[:cds] = subscribe_cds(service_name)
						end
						
						# Wait for cluster to be discovered
						# In practice, this might need async waiting
						cluster = @cache.get_cluster(service_name)
						raise ReloadError, "Failed to discover cluster: #{service_name}" unless cluster
						
						cluster
					end
				end
				
				# Discover endpoints for cluster (like ClusterClient discovers nodes)
				# @parameter cluster [Resources::Cluster] Cluster configuration
				# @returns [Array<Async::HTTP::Endpoint>] Discovered endpoints
				def discover_endpoints(cluster)
					@mutex.synchronize do
						# Check cache first
						if endpoints = @cache.get_endpoints(cluster.name)
							return endpoints
						end
						
						# Subscribe to EDS if not already subscribed
						unless @subscriptions[:"eds_#{cluster.name}"]
							@subscriptions[:"eds_#{cluster.name}"] = subscribe_eds(cluster.name)
						end
						
						# Wait for endpoints to be discovered
						endpoints = @cache.get_endpoints(cluster.name)
						raise ReloadError, "Failed to discover endpoints for cluster: #{cluster.name}" unless endpoints
						
						endpoints
					end
				end
				
				# Subscribe to CDS (Cluster Discovery Service)
				# @parameter service_name [String] Service name
				# @returns [Async::Task] Subscription task
				def subscribe_cds(service_name)
					@discovery_client.subscribe(
						DiscoveryClient::CLUSTER_TYPE,
						[service_name]
					) do |resources|
						resources.each do |resource|
							cluster = Resources::Cluster.new(resource)
							@cache.update_cluster(cluster)
						end
					end
				end
				
				# Subscribe to EDS (Endpoint Discovery Service)
				# @parameter cluster_name [String] Cluster name
				# @returns [Async::Task] Subscription task
				def subscribe_eds(cluster_name)
					@discovery_client.subscribe(
						DiscoveryClient::ENDPOINT_TYPE,
						[cluster_name]
					) do |resources|
						resources.each do |resource|
							assignment = Resources::ClusterLoadAssignment.new(resource)
							endpoints = assignment.endpoints.map do |ep|
								Async::HTTP::Endpoint.parse(ep.uri)
							end
							@cache.update_endpoints(cluster_name, endpoints)
						end
					end
				end
				
				# Close all subscriptions
				def close
					@subscriptions.each_value(&:stop)
					@subscriptions.clear
					@discovery_client.close
				end
			end
		end
	end
end
```

### 3. `Async::GRPC::XDS::DiscoveryClient`

Communicates with xDS control plane using ADS (Aggregated Discovery Service).

```ruby
module Async
	module GRPC
		module XDS
			# Client for xDS APIs (ADS or individual APIs)
			class DiscoveryClient
				# xDS API type URLs
				LISTENER_TYPE = "type.googleapis.com/envoy.config.listener.v3.Listener"
				ROUTE_TYPE = "type.googleapis.com/envoy.config.route.v3.RouteConfiguration"
				CLUSTER_TYPE = "type.googleapis.com/envoy.config.cluster.v3.Cluster"
				ENDPOINT_TYPE = "type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment"
				SECRET_TYPE = "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"
				
				# Initialize xDS discovery client
				# @parameter server_config [Hash] xDS server configuration from bootstrap
				def initialize(server_config)
					@server_uri = server_config["server_uri"]
					@channel_creds = build_credentials(server_config)
					@node = build_node_info
					@streams = {}
					@versions = {}  # Track version_info per type
					@nonces = {}     # Track nonces per type
					@mutex = Mutex.new
				end
				
				# Subscribe to resource type using ADS
				# (Aggregated Discovery Service - single stream for all types)
				# @parameter type_url [String] Resource type URL
				# @parameter resource_names [Array<String>] Resources to subscribe to
				# @yields [Array<Protobuf>] Updated resources
				# @returns [Async::Task] Subscription task
				def subscribe(type_url, resource_names, &block)
					stream = get_or_create_stream
					
					request = build_discovery_request(
						type_url: type_url,
						resource_names: resource_names,
						version_info: @versions[type_url] || "",
						nonce: @nonces[type_url] || ""
					)
					
					stream.write(request)
					
					# Process responses asynchronously
					Async do |task|
						begin
							stream.each do |response|
								process_response(response, type_url, &block)
							end
						rescue => error
							Console.error(self, error)
							# Stream closed, will reconnect on next subscription
							@mutex.synchronize do
								@streams.delete(:ads)
							end
							raise
						end
					end
				end
				
				# Close xDS discovery client
				def close
					@streams.each_value(&:close)
					@streams.clear
				end
				
			private
				
				def get_or_create_stream
					@mutex.synchronize do
						@streams[:ads] ||= create_ads_stream
					end
				end
				
				def create_ads_stream
					# Create bidirectional streaming RPC to ADS
					endpoint = Async::HTTP::Endpoint.parse(@server_uri)
					http_client = Async::HTTP::Client.new(endpoint)
					grpc_client = Async::GRPC::Client.new(http_client)
					
					# Use envoy.service.discovery.v3.AggregatedDiscoveryService
					# This would require the Envoy protobuf definitions
					interface = AggregatedDiscoveryServiceInterface.new(
						"envoy.service.discovery.v3.AggregatedDiscoveryService"
					)
					stub = grpc_client.stub(interface, "envoy.service.discovery.v3")
					
					# Create bidirectional stream
					stub.stream_aggregated_resources
				end
				
				def build_discovery_request(type_url:, resource_names:, version_info:, nonce:)
					# Build DiscoveryRequest protobuf
					# This requires Envoy protobuf definitions
					Envoy::Service::Discovery::V3::DiscoveryRequest.new(
						version_info: version_info,
						node: @node,
						resource_names: resource_names,
						type_url: type_url,
						response_nonce: nonce
					)
				end
				
				def build_node_info
					# Build node identification for xDS server
					Envoy::Config::Core::V3::Node.new(
						id: generate_node_id,
						cluster: ENV["XDS_CLUSTER"] || "default",
						metadata: build_metadata,
						locality: build_locality
					)
				end
				
				def process_response(response, type_url, &block)
					@mutex.synchronize do
						# Update version and nonce
						@versions[type_url] = response.version_info
						@nonces[type_url] = response.nonce
						
						# Deserialize resources
						resources = response.resources.map do |resource|
							# Deserialize Any protobuf to specific type
							deserialize_resource(resource, type_url)
						end
						
						# Yield to subscribers
						block.call(resources) if block_given?
					end
				end
				
				def deserialize_resource(resource, type_url)
					# Deserialize protobuf Any to specific message type
					# This requires Envoy protobuf definitions
					case type_url
					when CLUSTER_TYPE
						Envoy::Config::Cluster::V3::Cluster.decode(resource.value)
					when ENDPOINT_TYPE
						Envoy::Config::Endpoint::V3::ClusterLoadAssignment.decode(resource.value)
					# ... other types
					end
				end
				
				def generate_node_id
					# Generate unique node ID
					"#{Socket.gethostname}-#{Process.pid}-#{SecureRandom.hex(4)}"
				end
				
				def build_metadata
					# Build node metadata
					{}
				end
				
				def build_locality
					# Build locality information
					nil
				end
				
				def build_credentials(server_config)
					# Build channel credentials from config
					# Support Google Default Credentials, mTLS, etc.
					nil
				end
			end
		end
	end
end
```

### 4. `Async::GRPC::XDS::LoadBalancer`

Client-side load balancing with health checking. Similar to how `ClusterClient` selects nodes.

```ruby
module Async
	module GRPC
		module XDS
			# Client-side load balancing with health checking
			class LoadBalancer
				# Load balancing policies
				ROUND_ROBIN = :round_robin
				LEAST_REQUEST = :least_request
				RANDOM = :random
				RING_HASH = :ring_hash
				MAGLEV = :maglev
				
				# Initialize load balancer
				# @parameter context [Context] xDS context
				# @parameter cluster [Resources::Cluster] Cluster configuration
				# @parameter endpoints [Array<Async::HTTP::Endpoint>] Initial endpoints
				def initialize(context, cluster, endpoints)
					@context = context
					@cluster = cluster
					@endpoints = endpoints
					@policy = parse_policy(cluster.lb_policy)
					@health_status = {}  # Track health per endpoint
					@health_checker = HealthChecker.new(cluster.health_checks)
					@current_index = 0
					@in_flight_requests = {}  # Track in-flight requests per endpoint
					
					# Subscribe to endpoint updates
					watch_endpoints
					
					# Start health checking
					start_health_checks
				end
				
				# Get healthy endpoints
				# @returns [Array<Async::HTTP::Endpoint>] Healthy endpoints
				def healthy_endpoints
					@endpoints.select { |ep| healthy?(ep) }
				end
				
				# Pick next endpoint using load balancing policy
				# @returns [Async::HTTP::Endpoint, nil] Selected endpoint
				def pick
					healthy = healthy_endpoints
					return nil if healthy.empty?
					
					case @policy
					when ROUND_ROBIN
						pick_round_robin(healthy)
					when LEAST_REQUEST
						pick_least_request(healthy)
					when RANDOM
						pick_random(healthy)
					when RING_HASH
						pick_ring_hash(healthy)
					when MAGLEV
						pick_maglev(healthy)
					else
						healthy.first
					end
				end
				
				# Update endpoints from EDS
				# @parameter endpoints [Array<Async::HTTP::Endpoint>] New endpoints
				def update_endpoints(endpoints)
					@endpoints = endpoints
					@health_checker.update_endpoints(endpoints)
				end
				
				# Close load balancer
				def close
					@health_checker.close
				end
				
			private
				
				def healthy?(endpoint)
					@health_status[endpoint] != :unhealthy
				end
				
				def pick_round_robin(endpoints)
					@current_index = (@current_index + 1) % endpoints.size
					endpoints[@current_index]
				end
				
				def pick_least_request(endpoints)
					# Track in-flight requests and pick endpoint with fewest
					endpoints.min_by { |ep| @in_flight_requests[ep] || 0 }
				end
				
				def pick_random(endpoints)
					endpoints.sample
				end
				
				def pick_ring_hash(endpoints)
					# Consistent hashing implementation
					# Would need request context to hash
					endpoints.first  # Placeholder
				end
				
				def pick_maglev(endpoints)
					# Maglev hashing implementation
					endpoints.first  # Placeholder
				end
				
				def parse_policy(lb_policy)
					# Parse cluster LB policy to our constants
					case lb_policy
					when :ROUND_ROBIN then ROUND_ROBIN
					when :LEAST_REQUEST then LEAST_REQUEST
					when :RANDOM then RANDOM
					when :RING_HASH then RING_HASH
					when :MAGLEV then MAGLEV
					else ROUND_ROBIN
					end
				end
				
				def watch_endpoints
					# Subscribe to endpoint updates
					@context.subscribe_eds(@cluster.name) do |endpoints|
						update_endpoints(endpoints)
					end
				end
				
				def start_health_checks
					return unless @cluster.health_checks.any?
					
					Async do |task|
						loop do
							@endpoints.each do |endpoint|
								@health_status[endpoint] = @health_checker.check(endpoint)
							end
							
							# Sleep for health check interval
							interval = @cluster.health_checks.first&.interval || 30
							task.sleep(interval)
						end
					end
				end
			end
		end
	end
end
```

### 5. `Async::GRPC::XDS::HealthChecker`

Health checking for endpoints. Runs as async tasks.

```ruby
module Async
	module GRPC
		module XDS
			# Endpoint health checking
			class HealthChecker
				# Initialize health checker
				# @parameter health_checks [Array] Health check configurations from cluster
				def initialize(health_checks)
					@health_checks = health_checks
					@endpoints = []
					@tasks = {}  # Track health check tasks per endpoint
				end
				
				# Update endpoints to check
				# @parameter endpoints [Array<Async::HTTP::Endpoint>] Endpoints to check
				def update_endpoints(endpoints)
					# Stop checking removed endpoints
					removed = @endpoints - endpoints
					removed.each do |endpoint|
						@tasks[endpoint]&.stop
						@tasks.delete(endpoint)
					end
					
					# Start checking new endpoints
					added = endpoints - @endpoints
					added.each do |endpoint|
						start_checking(endpoint)
					end
					
					@endpoints = endpoints
				end
				
				# Check health of endpoint
				# @parameter endpoint [Async::HTTP::Endpoint] Endpoint to check
				# @returns [Symbol] :healthy, :unhealthy, or :unknown
				def check(endpoint)
					# Use cached health status if available
					# Otherwise perform check
					perform_check(endpoint)
				end
				
				# Close health checker
				def close
					@tasks.each_value(&:stop)
					@tasks.clear
				end
				
			private
				
				def start_checking(endpoint)
					@tasks[endpoint] = Async do |task|
						loop do
							perform_check(endpoint)
							
							interval = @health_checks.first&.interval || 30
							task.sleep(interval)
						end
					end
				end
				
				def perform_check(endpoint)
					health_check = @health_checks.first
					return :unknown unless health_check
					
					case health_check.type
					when :HTTP
						check_http_health(endpoint, health_check)
					when :gRPC
						check_grpc_health(endpoint, health_check)
					else
						:unknown
					end
				end
				
				def check_http_health(endpoint, health_check)
					# Perform HTTP health check
					# Use Async::HTTP::Client to make health check request
					:healthy  # Placeholder
				end
				
				def check_grpc_health(endpoint, health_check)
					# Perform gRPC health check
					# Use Async::GRPC::Client to call grpc.health.v1.Health service
					:healthy  # Placeholder
				end
			end
		end
	end
end
```

### 6. Resource Data Models

```ruby
module Async
	module GRPC
		module XDS
			module Resources
				# Represents a discovered cluster
				class Cluster
					attr_reader :name, :type, :lb_policy, :health_checks, :circuit_breakers
					
					def initialize(proto)
						@name = proto.name
						@type = proto.type
						@lb_policy = proto.lb_policy
						@health_checks = proto.health_checks
						@circuit_breakers = proto.circuit_breakers
					end
					
					def eds_cluster?
						@type == :EDS
					end
				end
				
				# Represents endpoint assignment
				class ClusterLoadAssignment
					attr_reader :cluster_name, :endpoints
					
					def initialize(proto)
						@cluster_name = proto.cluster_name
						@endpoints = proto.endpoints.flat_map do |locality_endpoints|
							locality_endpoints.lb_endpoints.map { |lb_ep| Endpoint.new(lb_ep) }
						end
					end
				end
				
				# Represents a single endpoint
				class Endpoint
					attr_reader :address, :port, :health_status, :metadata
					
					def initialize(lb_endpoint)
						socket_address = lb_endpoint.endpoint.address.socket_address
						@address = socket_address.address
						@port = socket_address.port_value
						@health_status = lb_endpoint.health_status
						@metadata = lb_endpoint.metadata
					end
					
					def healthy?
						@health_status == :HEALTHY || @health_status == :UNKNOWN
					end
					
					def uri
						"https://#{@address}:#{@port}"
					end
				end
			end
		end
	end
end
```

### 7. `Async::GRPC::XDS::ResourceCache`

Caches discovered resources.

```ruby
module Async
	module GRPC
		module XDS
			# Caches discovered xDS resources
			class ResourceCache
				def initialize
					@clusters = {}
					@endpoints = {}
					@mutex = Mutex.new
				end
				
				def get_cluster(name)
					@mutex.synchronize { @clusters[name] }
				end
				
				def update_cluster(cluster)
					@mutex.synchronize { @clusters[cluster.name] = cluster }
				end
				
				def get_endpoints(cluster_name)
					@mutex.synchronize { @endpoints[cluster_name] }
				end
				
				def update_endpoints(cluster_name, endpoints)
					@mutex.synchronize { @endpoints[cluster_name] = endpoints }
				end
			end
		end
	end
end
```

## Bootstrap Configuration

xDS clients require a bootstrap configuration that specifies control plane details:

```json
{
  "xds_servers": [
    {
      "server_uri": "xds.example.com:443",
      "channel_creds": [
        {
          "type": "google_default"
        }
      ],
      "server_features": ["xds_v3"]
    }
  ],
  "node": {
    "id": "async-grpc-client-001",
    "cluster": "production",
    "locality": {
      "zone": "us-central1-a"
    },
    "metadata": {
      "TRAFFICDIRECTOR_GCP_PROJECT_NUMBER": "123456789"
    }
  },
  "certificate_providers": {
    "default": {
      "plugin_name": "file_watcher",
      "config": {
        "certificate_file": "/path/to/cert.pem",
        "private_key_file": "/path/to/key.pem",
        "ca_certificate_file": "/path/to/ca.pem",
        "refresh_interval": "600s"
      }
    }
  }
}
```

Bootstrap can be loaded from:
1. Explicit parameter to `XDS::Client.new`
2. Environment variable `GRPC_XDS_BOOTSTRAP`
3. Default file location `~/.config/grpc/bootstrap.json`

## Usage Examples

### Basic Service Discovery

```ruby
require "async/grpc"
require "async/grpc/xds"

# Create xDS client (like SentinelClient)
xds_client = Async::GRPC::XDS::Client.new(
	"myservice",
	bootstrap: "/path/to/bootstrap.json"
)

# Use it exactly like Async::GRPC::Client
Async do
	stub = xds_client.stub(MyServiceInterface, "myservice")
	
	# Make calls - automatically load balanced across discovered endpoints
	response = stub.my_method(request)
	puts response.message
ensure
	xds_client.close
end
```

### With Default Bootstrap

```ruby
# Uses GRPC_XDS_BOOTSTRAP env var or ~/.config/grpc/bootstrap.json
xds_client = Async::GRPC::XDS::Client.new("myservice")

Async do
	# Use client normally
	xds_client.stub(MyServiceInterface, "myservice") do |stub|
		response = stub.say_hello(request)
	end
ensure
	xds_client.close
end
```

### Manual Endpoint Resolution

```ruby
xds_client = Async::GRPC::XDS::Client.new("myservice")

# Get all healthy endpoints
endpoints = xds_client.resolve_endpoints

endpoints.each do |endpoint|
	puts "Available backend: #{endpoint.authority}"
end

# Use load balancer directly
lb = xds_client.instance_variable_get(:@load_balancer)

10.times do
	backend = lb.pick
	puts "Selected: #{backend.authority}"
end
```

### Error Handling

```ruby
xds_client = Async::GRPC::XDS::Client.new("myservice")

Async do
	begin
		stub = xds_client.stub(MyServiceInterface, "myservice")
		response = stub.my_method(request)
	rescue Async::GRPC::XDS::NoEndpointsError => error
		puts "No endpoints available: #{error.message}"
		# Fallback to static endpoint or retry later
	rescue Async::GRPC::XDS::ConfigurationError => error
		puts "Configuration error: #{error.message}"
		# Check bootstrap configuration
	end
ensure
	xds_client.close
end
```

## Integration with Existing Code

Since `XDS::Client` implements `Protocol::HTTP::Middleware` (same as `Async::GRPC::Client`), it can be used as a drop-in replacement:

```ruby
# Works with any code expecting Async::GRPC::Client interface
def make_call(client)
	client.stub(MyServiceInterface, "myservice") do |stub|
		stub.say_hello(request)
	end
end

# Can use either regular client or xDS client
regular_client = Async::GRPC::Client.open(endpoint)
xds_client = Async::GRPC::XDS::Client.new("myservice")

make_call(regular_client)  # Works
make_call(xds_client)     # Also works!
```

## Implementation Phases

### Phase 1: Core Infrastructure
- [ ] Bootstrap configuration loading
- [ ] Basic `XDS::Client` wrapper implementation
- [ ] `XDS::Context` for state management
- [ ] `XDS::ResourceCache` for discovered resources
- [ ] Basic endpoint resolution

### Phase 2: Discovery Services
- [ ] `XDS::DiscoveryClient` with ADS support
- [ ] CDS (Cluster Discovery) implementation
- [ ] EDS (Endpoint Discovery) implementation
- [ ] Resource subscription and updates
- [ ] Version tracking and ACK/NACK

### Phase 3: Load Balancing
- [ ] `XDS::LoadBalancer` base implementation
- [ ] Round-robin policy
- [ ] Least-request policy
- [ ] Random policy
- [ ] Ring-hash/consistent hashing
- [ ] Maglev policy

### Phase 4: Health Checking
- [ ] `XDS::HealthChecker` implementation
- [ ] HTTP health checks
- [ ] gRPC health checks
- [ ] Health status aggregation
- [ ] Active/passive health checking

### Phase 5: Advanced Features
- [ ] LDS (Listener Discovery) for servers
- [ ] RDS (Route Discovery) for routing
- [ ] SDS (Secret Discovery) for mTLS
- [ ] Circuit breakers
- [ ] Retry policies
- [ ] Timeout configuration
- [ ] Rate limiting

### Phase 6: Integration & Testing
- [ ] Integration tests with mock xDS server
- [ ] Error handling and recovery tests
- [ ] Load balancing distribution tests
- [ ] Health check integration tests
- [ ] Performance benchmarks

## Standards and Specifications

### xDS Protocol Specifications
- [xDS REST and gRPC protocol](https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol)
- [Universal Data Plane API (UDPA)](https://github.com/cncf/xds)
- [gRFC A27: xDS-Based Global Load Balancing](https://github.com/grpc/proposal/blob/master/A27-xds-global-load-balancing.md)
- [gRFC A28: xDS Traffic Splitting and Routing](https://github.com/grpc/proposal/blob/master/A28-xds-traffic-splitting-and-routing.md)

### Protobuf Definitions
- [envoy.config.listener.v3](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/listener/v3/listener.proto)
- [envoy.config.route.v3](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/route/v3/route.proto)
- [envoy.config.cluster.v3](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/cluster.proto)
- [envoy.config.endpoint.v3](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/endpoint/v3/endpoint.proto)
- [envoy.service.discovery.v3](https://www.envoyproxy.io/docs/envoy/latest/api-v3/service/discovery/v3/discovery.proto)

### Compatible Systems
- **Google Cloud Traffic Director** - Managed xDS control plane
- **Istio** - Service mesh with xDS control plane
- **Linkerd** - Service mesh with xDS support
- **Consul Connect** - Service mesh with xDS API
- **Envoy Proxy** - Reference xDS implementation

## Testing Strategy

### Unit Tests
- Bootstrap configuration loading and validation
- Resource deserialization
- Load balancing algorithms
- Health checking logic
- Cache invalidation

### Integration Tests with Docker Compose

Following the pattern from `async-redis`, integration tests use Docker Compose to spin up a complete xDS test environment with:
- xDS control plane (using go-control-plane or Envoy)
- Multiple backend gRPC servers
- Health check services

#### Docker Compose Setup

Create `xds/docker-compose.yaml`:

```yaml
services:
  # xDS control plane (using go-control-plane test server)
  xds-control-plane:
    image: envoyproxy/go-control-plane:latest
    command: >
      /go-control-plane
      -alsologtostderr
      -v 2
      -mode xds
      -server_type ADS
      -port 18000
    ports:
      - "18000:18000"
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "18000"]
      interval: 1s
      timeout: 3s
      retries: 30

  # Backend gRPC server 1
  backend-1:
    build:
      context: .
      dockerfile: xds/Dockerfile.backend
    environment:
      - PORT=50051
      - SERVICE_NAME=myservice
    ports:
      - "50051:50051"
    depends_on:
      xds-control-plane:
        condition: service_healthy

  # Backend gRPC server 2
  backend-2:
    build:
      context: .
      dockerfile: xds/Dockerfile.backend
    environment:
      - PORT=50052
      - SERVICE_NAME=myservice
    ports:
      - "50052:50052"
    depends_on:
      xds-control-plane:
        condition: service_healthy

  # Backend gRPC server 3
  backend-3:
    build:
      context: .
      dockerfile: xds/Dockerfile.backend
    environment:
      - PORT=50053
      - SERVICE_NAME=myservice
    ports:
      - "50053:50053"
    depends_on:
      xds-control-plane:
        condition: service_healthy

  # Test runner
  tests:
    image: ruby:${RUBY_VERSION:-latest}
    volumes:
      - ../:/code
    working_dir: /code
    command: bash -c "bundle install && bundle exec sus xds/test"
    environment:
      - COVERAGE=${COVERAGE}
      - XDS_SERVER_URI=xds-control-plane:18000
    depends_on:
      - xds-control-plane
      - backend-1
      - backend-2
      - backend-3
```

#### Test Structure

Create `xds/test/async/grpc/xds/client.rb`:

```ruby
# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async/grpc/xds/client"
require "sus/fixtures/async"
require "async/http/endpoint"

describe Async::GRPC::XDS::Client do
	include Sus::Fixtures::Async::ReactorContext
	
	let(:xds_server_uri) {ENV["XDS_SERVER_URI"] || "xds-control-plane:18000"}
	let(:service_name) {"myservice"}
	
	let(:bootstrap) {
		{
			"xds_servers" => [
				{
					"server_uri" => xds_server_uri,
					"channel_creds" => [{"type" => "insecure"}]
				}
			],
			"node" => {
				"id" => "test-client-#{Process.pid}",
				"cluster" => "test"
			}
		}
	}
	
	let(:client) {subject.new(service_name, bootstrap: bootstrap)}
	
	it "can resolve endpoints" do
		endpoints = client.resolve_endpoints
		
		expect(endpoints).not_to be_empty
		expect(endpoints.size).to be >= 1
	end
	
	it "can make RPC calls through xDS" do
		stub = client.stub(MyServiceInterface, service_name)
		
		request = MyService::HelloRequest.new(name: "test")
		response = stub.say_hello(request)
		
		expect(response).to be_a(MyService::HelloReply)
		expect(response.message).to match(/test/)
	end
	
	it "load balances across multiple endpoints" do
		# Make multiple calls and verify they hit different backends
		endpoints_used = Set.new
		
		10.times do
			stub = client.stub(MyServiceInterface, service_name)
			request = MyService::HelloRequest.new(name: "test")
			response = stub.say_hello(request)
			
			# Extract backend info from response metadata or headers
			endpoints_used << extract_backend(response)
		end
		
		# Should use multiple backends (depending on LB policy)
		expect(endpoints_used.size).to be > 1
	end
	
	it "handles endpoint failures gracefully" do
		# Start with healthy endpoints
		endpoints = client.resolve_endpoints
		expect(endpoints).not_to be_empty
		
		# Simulate endpoint failure (stop one backend)
		# xDS should update and remove failed endpoint
		
		# Wait for xDS update
		sleep 5
		
		# Should still be able to make calls (using remaining endpoints)
		stub = client.stub(MyServiceInterface, service_name)
		request = MyService::HelloRequest.new(name: "test")
		response = stub.say_hello(request)
		
		expect(response).to be_a(MyService::HelloReply)
	end
	
	it "reloads configuration on errors" do
		# Make initial call
		stub = client.stub(MyServiceInterface, service_name)
		request = MyService::HelloRequest.new(name: "test")
		response = stub.say_hello(request)
		expect(response).to be_a(MyService::HelloReply)
		
		# Invalidate cache (simulate endpoint change)
		client.instance_variable_get(:@load_balancer)&.update_endpoints([])
		
		# Should reload and work again
		response = stub.say_hello(request)
		expect(response).to be_a(MyService::HelloReply)
	end
	
	private
	
	def extract_backend(response)
		# Extract backend identifier from response
		# This depends on your test service implementation
		response.metadata["backend-id"] || "unknown"
	end
end
```

#### Running Integration Tests

```bash
# Start docker compose environment
cd xds
docker compose up -d

# Wait for services to be ready
docker compose ps

# Run tests
docker compose run --rm tests

# Or run locally (if services are accessible)
bundle exec sus xds/test

# Cleanup
docker compose down
```

#### Mock xDS Control Plane

For simpler testing, use a mock xDS server:

```ruby
# xds/test/mock_xds_server.rb
module Async
	module GRPC
		module XDS
			module Test
				# Simple mock xDS server for testing
				class MockControlPlane
					def initialize
						@clusters = {}
						@endpoints = {}
					end
					
					def add_cluster(name, config)
						@clusters[name] = config
					end
					
					def add_endpoints(cluster_name, endpoints)
						@endpoints[cluster_name] = endpoints
					end
					
					# Implement ADS server interface
					def stream_aggregated_resources(requests)
						# Yield DiscoveryResponse messages
					end
				end
			end
		end
	end
end
```

### System Tests
- Integration with Google Cloud Traffic Director
- Integration with Istio
- Multi-endpoint failover scenarios
- Load balancing distribution
- Health check integration

## Security Considerations

### Authentication
- Support for Google Default Credentials
- Support for mTLS with SDS
- Support for OAuth2 tokens
- Channel credential configuration

### Authorization
- RBAC integration via xDS
- Resource filtering by permissions
- Secure communication with control plane

### Certificate Management
- Dynamic certificate rotation via SDS
- Certificate validation
- CRL/OCSP checking
- Certificate provider plugins

## Performance Considerations

### Resource Caching
- Cache discovered resources locally
- Version-based cache invalidation
- Memory-efficient resource storage

### Connection Pooling
- Reuse HTTP/2 connections to backends
- Connection pool per endpoint
- Idle connection cleanup

### Async Operations
- Non-blocking xDS subscriptions
- Async health checks
- Parallel endpoint discovery

## Open Questions

1. **Incremental vs. State-of-the-World** - Which xDS update mode to use?
   - Incremental allows selective updates
   - State-of-the-world is simpler but more bandwidth
   - **Recommendation**: Start with state-of-the-world, add incremental later

2. **Control Plane Failover** - How to handle control plane unavailability?
   - Cache last known good configuration
   - Fall back to static configuration
   - Multiple control plane endpoints
   - **Recommendation**: Cache last known config, support multiple endpoints

3. **Protobuf Dependencies** - How to handle Envoy protos?
   - Bundle pre-generated Ruby protos
   - Generate from .proto files at build time
   - Separate gem for Envoy proto definitions
   - **Recommendation**: Separate gem (`envoy-protos-ruby`) for proto definitions

4. **Backwards Compatibility** - How to maintain compatibility?
   - Make xDS optional dependency
   - Graceful degradation without xDS
   - Clear migration path from static to dynamic
   - **Recommendation**: Optional dependency, wrapper pattern maintains compatibility

5. **Server-Side xDS** - Priority for server features?
   - LDS for dynamic listener configuration
   - RDS for advanced routing
   - Integration with existing `Dispatcher`
   - **Recommendation**: Focus on client-side first, server-side later

## Related Work

- [grpc-go xDS implementation](https://github.com/grpc/grpc-go/tree/master/xds)
- [grpc-java xDS implementation](https://github.com/grpc/grpc-java/tree/master/xds)
- [Envoy data plane implementation](https://github.com/envoyproxy/envoy)
- [go-control-plane](https://github.com/envoyproxy/go-control-plane) - Reference control plane

## References

- [gRPC xDS Documentation](https://grpc.io/docs/guides/xds/)
- [Envoy xDS Documentation](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/dynamic_configuration)
- [Traffic Director Documentation](https://cloud.google.com/traffic-director/docs)
- [CNCF xDS API Working Group](https://github.com/cncf/xds)
