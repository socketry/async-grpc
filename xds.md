# xDS Support for Async::GRPC

This document outlines the design and implementation of xDS (Discovery Service) support for `async-grpc`, enabling dynamic service discovery and configuration for gRPC clients and servers.

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

### URI Scheme

xDS endpoints use a special URI scheme:

```ruby
# Basic xDS endpoint
endpoint = Async::GRPC::XDS::Endpoint.parse("xds:///myservice")

# With explicit control plane
endpoint = Async::GRPC::XDS::Endpoint.parse("xds://control-plane.example.com/myservice")

# With bootstrap configuration
endpoint = Async::GRPC::XDS::Endpoint.parse("xds:///myservice", bootstrap: "/path/to/bootstrap.json")
```

### Component Structure

```
Async::GRPC::XDS
├── Endpoint              # Main entry point for xDS-enabled connections
├── Context               # Manages xDS state and subscriptions
├── Client                # xDS API client (ADS or individual xDS APIs)
├── ResourceCache         # Caches discovered resources
├── LoadBalancer          # Client-side load balancing
├── HealthChecker         # Endpoint health checking
└── Resources             # Resource data models
    ├── Listener
    ├── RouteConfiguration
    ├── Cluster
    ├── ClusterLoadAssignment
    └── Secret
```

## Core Components

### 1. `Async::GRPC::XDS::Endpoint`

The main entry point that wraps standard endpoints with xDS capabilities:

```ruby
module Async
	module GRPC
		module XDS
			class Endpoint
				# Parse an xDS URI into an endpoint
				# @parameter uri [String] xDS URI (e.g., "xds:///myservice")
				# @parameter bootstrap [String, Hash, nil] Bootstrap config file path or hash
				# @returns [Endpoint] xDS-enabled endpoint
				def self.parse(uri, bootstrap: nil)
					# Parse xDS URI
					# Load bootstrap configuration
					# Create endpoint instance
				end
				
				# Initialize with parsed configuration
				# @parameter service_name [String] Target service name
				# @parameter control_plane [URI, nil] Control plane endpoint
				# @parameter bootstrap [Hash, nil] Bootstrap configuration
				def initialize(service_name, control_plane: nil, bootstrap: nil)
					@service_name = service_name
					@control_plane = control_plane
					@bootstrap = bootstrap || load_default_bootstrap
					@context = Context.new(self, @bootstrap)
				end
				
				# Connect to the service using xDS-discovered endpoints
				# @yields [Async::HTTP::Endpoint] Individual backend endpoint
				# @returns [Array<Async::HTTP::Endpoint>] Available endpoints
				def connect(&block)
					@context.resolve_endpoints(@service_name, &block)
				end
				
				# Get load balancer for this endpoint
				# @returns [LoadBalancer] Configured load balancer
				def load_balancer
					@context.load_balancer_for(@service_name)
				end
				
				# Close xDS subscriptions and cleanup
				def close
					@context.close
				end
			end
		end
	end
end
```

### 2. `Async::GRPC::XDS::Context`

Manages xDS subscriptions and maintains discovered resource state:

```ruby
module Async
	module GRPC
		module XDS
			class Context
				# Initialize xDS context
				# @parameter endpoint [Endpoint] Parent endpoint
				# @parameter bootstrap [Hash] Bootstrap configuration
				def initialize(endpoint, bootstrap)
					@endpoint = endpoint
					@bootstrap = bootstrap
					@client = Client.new(bootstrap["xds_servers"].first)
					@cache = ResourceCache.new
					@subscriptions = {}
					@load_balancers = {}
				end
				
				# Resolve endpoints for a service
				# @parameter service_name [String] Service to resolve
				# @yields [Async::HTTP::Endpoint] Each discovered endpoint
				# @returns [Array<Async::HTTP::Endpoint>] All available endpoints
				def resolve_endpoints(service_name, &block)
					# Subscribe to CDS for cluster discovery
					cluster = discover_cluster(service_name)
					
					# Subscribe to EDS for endpoint discovery
					endpoints = discover_endpoints(cluster)
					
					# Filter healthy endpoints
					healthy_endpoints = filter_healthy(endpoints)
					
					if block_given?
						healthy_endpoints.each(&block)
					end
					
					healthy_endpoints
				end
				
				# Get or create load balancer for service
				# @parameter service_name [String] Service name
				# @returns [LoadBalancer] Load balancer instance
				def load_balancer_for(service_name)
					@load_balancers[service_name] ||= begin
						cluster = @cache.get_cluster(service_name)
						LoadBalancer.new(self, cluster)
					end
				end
				
				# Subscribe to resource updates
				# @parameter type_url [String] xDS resource type URL
				# @parameter resource_names [Array<String>] Resource names to watch
				# @yields [Resource] Updated resources
				def subscribe(type_url, resource_names, &block)
					@subscriptions[type_url] ||= {}
					resource_names.each do |name|
						@subscriptions[type_url][name] = block
					end
					
					@client.subscribe(type_url, resource_names)
				end
				
				# Close all subscriptions
				def close
					@client.close
					@load_balancers.each_value(&:close)
				end
				
			private
				
				def discover_cluster(service_name)
					# Implement CDS (Cluster Discovery Service)
				end
				
				def discover_endpoints(cluster)
					# Implement EDS (Endpoint Discovery Service)
				end
				
				def filter_healthy(endpoints)
					# Filter based on health checks
				end
			end
		end
	end
end
```

### 3. `Async::GRPC::XDS::Client`

Communicates with xDS control plane:

```ruby
module Async
	module GRPC
		module XDS
			# Client for xDS APIs (ADS or individual APIs)
			class Client
				# xDS API type URLs
				LISTENER_TYPE = "type.googleapis.com/envoy.config.listener.v3.Listener"
				ROUTE_TYPE = "type.googleapis.com/envoy.config.route.v3.RouteConfiguration"
				CLUSTER_TYPE = "type.googleapis.com/envoy.config.cluster.v3.Cluster"
				ENDPOINT_TYPE = "type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment"
				SECRET_TYPE = "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret"
				
				# Initialize xDS client
				# @parameter server_config [Hash] xDS server configuration from bootstrap
				def initialize(server_config)
					@server_uri = server_config["server_uri"]
					@channel_creds = build_credentials(server_config)
					@node = build_node_info
					@streams = {}
				end
				
				# Subscribe to resource type using ADS
				# (Aggregated Discovery Service - single stream for all types)
				# @parameter type_url [String] Resource type URL
				# @parameter resource_names [Array<String>] Resources to subscribe to
				# @yields [Resource] Updated resources
				def subscribe(type_url, resource_names)
					stream = get_or_create_stream
					
					request = build_discovery_request(
						type_url: type_url,
						resource_names: resource_names,
						version_info: @versions[type_url] || "",
						nonce: @nonces[type_url] || ""
					)
					
					stream.write(request)
					
					# Process responses asynchronously
					Async do
						stream.each do |response|
							process_response(response, &Proc.new)
						end
					end
				end
				
				# Close xDS client
				def close
					@streams.each_value(&:close)
				end
				
			private
				
				def get_or_create_stream
					@streams[:ads] ||= create_ads_stream
				end
				
				def create_ads_stream
					# Create bidirectional streaming RPC to ADS
					endpoint = Async::HTTP::Endpoint.parse(@server_uri)
					grpc_client = Async::GRPC::Client.open(endpoint)
					
					# Use envoy.service.discovery.v3.AggregatedDiscoveryService
					interface = AggregatedDiscoveryServiceInterface.new(
						"envoy.service.discovery.v3.AggregatedDiscoveryService"
					)
					stub = grpc_client.stub(interface)
					
					stub.stream_aggregated_resources
				end
				
				def build_discovery_request(type_url:, resource_names:, version_info:, nonce:)
					# Build DiscoveryRequest protobuf
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
				
				def process_response(response)
					# Parse and validate response
					# Update version and nonce
					# Deserialize resources
					# Yield to subscribers
				end
			end
		end
	end
end
```

### 4. `Async::GRPC::XDS::LoadBalancer`

Client-side load balancing with health checking:

```ruby
module Async
	module GRPC
		module XDS
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
				def initialize(context, cluster)
					@context = context
					@cluster = cluster
					@policy = parse_policy(cluster.lb_policy)
					@endpoints = []
					@health_checker = HealthChecker.new(cluster.health_checks)
					@current_index = 0
					
					# Subscribe to endpoint updates
					watch_endpoints
				end
				
				# Pick next endpoint using load balancing policy
				# @returns [Async::HTTP::Endpoint, nil] Selected endpoint
				def pick
					healthy = @endpoints.select { |ep| @health_checker.healthy?(ep) }
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
					else
						healthy.first
					end
				end
				
				# Update endpoints from EDS
				# @parameter endpoints [Array<Resources::Endpoint>] New endpoints
				def update_endpoints(endpoints)
					@endpoints = endpoints.map { |ep| build_http_endpoint(ep) }
					@health_checker.update_endpoints(@endpoints)
				end
				
				# Close load balancer
				def close
					@health_checker.close
				end
				
			private
				
				def pick_round_robin(endpoints)
					@current_index = (@current_index + 1) % endpoints.size
					endpoints[@current_index]
				end
				
				def pick_least_request(endpoints)
					# Track in-flight requests and pick endpoint with fewest
					endpoints.min_by { |ep| in_flight_count(ep) }
				end
				
				def pick_random(endpoints)
					endpoints.sample
				end
				
				def pick_ring_hash(endpoints)
					# Consistent hashing implementation
				end
				
				def watch_endpoints
					@context.subscribe(Client::ENDPOINT_TYPE, [@cluster.name]) do |assignment|
						update_endpoints(assignment.endpoints)
					end
				end
			end
		end
	end
end
```

### 5. Resource Data Models

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
						"http://#{@address}:#{@port}"
					end
				end
				
				# Represents a listener configuration
				class Listener
					attr_reader :name, :address, :filter_chains
					
					def initialize(proto)
						@name = proto.name
						@address = proto.address
						@filter_chains = proto.filter_chains
					end
				end
				
				# Represents route configuration
				class RouteConfiguration
					attr_reader :name, :virtual_hosts
					
					def initialize(proto)
						@name = proto.name
						@virtual_hosts = proto.virtual_hosts.map { |vh| VirtualHost.new(vh) }
					end
				end
				
				class VirtualHost
					attr_reader :name, :domains, :routes
					
					def initialize(proto)
						@name = proto.name
						@domains = proto.domains
						@routes = proto.routes
					end
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
1. Explicit parameter to `Endpoint.parse`
2. Environment variable `GRPC_XDS_BOOTSTRAP`
3. Default file location `~/.config/grpc/bootstrap.json`

## Integration with Async::GRPC::Client

```ruby
module Async
	module GRPC
		class Client
			# Enhanced to support xDS endpoints
			def self.open(endpoint = self::ENDPOINT, headers: Protocol::HTTP::Headers.new, **options)
				# Check if endpoint is xDS-enabled
				if endpoint.is_a?(XDS::Endpoint)
					# Use xDS load balancer to select backend
					lb = endpoint.load_balancer
					backend_endpoint = lb.pick
					
					# Create client with selected backend
					client = connect(backend_endpoint)
					grpc_client = new(client, headers: headers, **options)
					
					# Wrap with load balancer for automatic failover
					XDS::BalancedClient.new(grpc_client, lb)
				else
					# Standard endpoint handling
					endpoint = Async::HTTP::Endpoint.parse(endpoint) if endpoint.is_a?(String)
					client = connect(endpoint)
					new(client, headers: headers, **options)
				end
			end
		end
	end
end
```

## Usage Examples

### Basic Service Discovery

```ruby
require "async/grpc"
require "async/grpc/xds"

# Parse xDS endpoint
endpoint = Async::GRPC::XDS::Endpoint.parse("xds:///myservice")

# Create client - automatically uses xDS for discovery
Async::GRPC::Client.open(endpoint) do |client|
	stub = client.stub(MyServiceInterface, "myservice")
	
	# Make calls - automatically load balanced across discovered endpoints
	response = stub.my_method(request)
	puts response.message
end
```

### Manual Endpoint Resolution

```ruby
require "async/grpc/xds"

endpoint = Async::GRPC::XDS::Endpoint.parse("xds:///myservice")

# Get all healthy endpoints
endpoints = endpoint.connect

endpoints.each do |backend|
	puts "Available backend: #{backend.authority}"
end

# Use load balancer directly
lb = endpoint.load_balancer

10.times do
	backend = lb.pick
	puts "Selected: #{backend.authority}"
end
```

### With Custom Bootstrap

```ruby
bootstrap = {
	"xds_servers" => [
		{
			"server_uri" => "control-plane.example.com:443",
			"channel_creds" => [{"type" => "google_default"}]
		}
	],
	"node" => {
		"id" => "my-app-instance-001",
		"cluster" => "production"
	}
}

endpoint = Async::GRPC::XDS::Endpoint.parse(
	"xds:///myservice",
	bootstrap: bootstrap
)

Async::GRPC::Client.open(endpoint) do |client|
	# Use client normally
end
```

### Server-Side xDS (Listener Discovery)

```ruby
require "async/grpc/xds"

# Create xDS-enabled server
xds_config = Async::GRPC::XDS::ServerConfig.parse("xds:///myserver")

Async do
	# Server configuration discovered via LDS
	listeners = xds_config.listeners
	
	listeners.each do |listener|
		endpoint = Async::HTTP::Endpoint.parse(listener.uri)
		server = Async::HTTP::Server.for(endpoint, dispatcher)
		
		Async do
			server.run
		end
	end
end
```

## Implementation Phases

### Phase 1: Core Infrastructure
- [ ] Parse xDS URIs
- [ ] Bootstrap configuration loading
- [ ] Basic `XDS::Endpoint` implementation
- [ ] `XDS::Context` for state management
- [ ] `XDS::ResourceCache` for discovered resources

### Phase 2: Discovery Services
- [ ] `XDS::Client` with ADS support
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

### Phase 6: Integration
- [ ] Integration with `Async::GRPC::Client`
- [ ] Integration with `Async::GRPC::Dispatcher`
- [ ] Interceptor support
- [ ] Observability (metrics, tracing)
- [ ] Testing utilities

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
- URI parsing and validation
- Bootstrap configuration loading
- Resource deserialization
- Load balancing algorithms
- Health checking logic

### Integration Tests
- Mock xDS control plane
- Full discovery flow (CDS + EDS)
- Load balancer endpoint selection
- Health check state transitions
- Resource update handling

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

2. **Control Plane Failover** - How to handle control plane unavailability?
   - Cache last known good configuration
   - Fall back to static configuration
   - Multiple control plane endpoints

3. **Server-Side xDS** - Priority for server features?
   - LDS for dynamic listener configuration
   - RDS for advanced routing
   - Integration with existing `Dispatcher`

4. **Protobuf Dependencies** - How to handle Envoy protos?
   - Bundle pre-generated Ruby protos
   - Generate from .proto files at build time
   - Separate gem for Envoy proto definitions

5. **Backwards Compatibility** - How to maintain compatibility?
   - Make xDS optional dependency
   - Graceful degradation without xDS
   - Clear migration path from static to dynamic

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
