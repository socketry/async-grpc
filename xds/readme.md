# xDS Integration Tests

This directory contains Docker Compose configuration and test files for xDS integration testing, following the same pattern as `async-redis` (Sentinel and Cluster tests).

## Setup

The Docker Compose setup includes:
- **xds-control-plane**: xDS control plane server (using go-control-plane)
- **backend-1, backend-2, backend-3**: Multiple gRPC backend servers
- **tests**: Test runner container

## Running Tests

### Start the environment

```bash
cd xds
bundle install  # generates gems.locked for Docker build
docker compose up -d
```

### Wait for services to be ready

```bash
docker compose ps
```

All services should show as "healthy" or "running".

### Run tests

```bash
# Run tests in docker compose
docker compose run --rm tests

# Or run tests locally (if services are accessible)
# Set XDS_SERVER_URI environment variable
export XDS_SERVER_URI=xds-control-plane:18000
bundle exec sus xds/test
```

### Cleanup

```bash
docker compose down
```

## Test Structure

Tests are located in `xds/test/async/grpc/xds/` and follow the same pattern as other async-grpc tests:

- `client.rb`: Tests for `Async::GRPC::XDS::Client`
- Tests use `Sus::Fixtures::Async::ReactorContext` for async test support
- Tests connect to docker compose services using service names (e.g., `xds-control-plane:18000`)

## Environment Variables

- `XDS_SERVER_URI`: xDS control plane server URI (default: `xds-control-plane:18000`)
- `RUBY_VERSION`: Ruby version for test container (default: `latest`)
- `COVERAGE`: Enable code coverage reporting

## Backend Servers

The backend servers (`backend-1`, `backend-2`, `backend-3`) are simple gRPC servers that:
- Implement the test service interface
- Include backend ID in response metadata
- Can be used to test load balancing and failover

See `backend_server.rb` for implementation details.

## Mock xDS Control Plane

For simpler unit testing, you can use a mock xDS server instead of the full Docker Compose setup. See the test files for examples of mocking xDS responses.

## Troubleshooting

### Services not starting

Check logs:
```bash
docker compose logs xds-control-plane
docker compose logs backend-1
```

### Tests failing to connect

Ensure services are healthy:
```bash
docker compose ps
```

Check network connectivity:
```bash
docker compose exec tests ping xds-control-plane
```

## Protobuf Setup

The xDS implementation uses Envoy protobuf definitions. Protos come from [envoyproxy/envoy](https://github.com/envoyproxy/envoy) (`api/`) or [envoyproxy/data-plane-api](https://github.com/envoyproxy/data-plane-api). Use **xDS v3** (v2 is deprecated).

### Required protobuf files

- `envoy/service/discovery/v3/discovery.proto` - DiscoveryRequest/Response.
- `envoy/service/discovery/v3/ads.proto` - AggregatedDiscoveryService.
- `envoy/config/cluster/v3/cluster.proto` - Cluster (CDS).
- `envoy/config/endpoint/v3/endpoint.proto` - ClusterLoadAssignment (EDS).
- `envoy/config/core/v3/base.proto` - Node, Locality, etc.
- `google/protobuf/any.proto` - For Any type in DiscoveryResponse.

### Generating Ruby code

```bash
protoc --ruby_out=lib \
  --proto_path=vendor/envoy-api \
  envoy/service/discovery/v3/discovery.proto \
  envoy/service/discovery/v3/ads.proto \
  envoy/config/cluster/v3/cluster.proto \
  envoy/config/endpoint/v3/endpoint.proto \
  envoy/config/core/v3/base.proto
```

Lock the Envoy API version (submodule tag or commit) for compatibility.
