# Envoy Protobuf Definitions

This directory contains vendored Envoy protobuf definitions for xDS support.

## Source

These files come from [envoyproxy/data-plane-api](https://github.com/envoyproxy/data-plane-api).

## Contents

- `envoy/service/discovery/v3/` - Discovery service definitions (ADS, DiscoveryRequest/Response)
- `envoy/config/cluster/v3/` - Cluster definitions (CDS)
- `envoy/config/endpoint/v3/` - Endpoint definitions (EDS)
- `envoy/config/listener/v3/` - Listener definitions (LDS)
- `envoy/config/route/v3/` - Route definitions (RDS)
- `envoy/config/core/v3/` - Core types (Node, Address, etc.)
- `envoy/extensions/transport_sockets/tls/v3/` - TLS/Secret definitions (SDS)
- `google/protobuf/` - Google protobuf well-known types

## Updating

To update these files, run:

```bash
./xds/update_protos.sh
```

Or manually:

```bash
# Clone envoy data-plane-api
git clone --depth 1 https://github.com/envoyproxy/data-plane-api.git /tmp/envoy-api

# Copy needed files
cp -r /tmp/envoy-api/envoy proto/
cp -r /tmp/envoy-api/google proto/

# Cleanup
rm -rf /tmp/envoy-api
```

## Generating Ruby Code

After updating proto files, generate Ruby classes:

```bash
bundle exec bake async:grpc:xds:generate_protos
```

## Version

These files are from the latest `main` branch of:
- `envoyproxy/data-plane-api` - Envoy API definitions
- `protocolbuffers/protobuf` - Google protobuf well-known types
- `googleapis/api-common-protos` - Google RPC status

To lock to a specific version, modify `xds/update_protos.sh` to check out specific tags:

```bash
cd /tmp/envoy-api
git checkout v1.30.0  # Use specific Envoy version
# Then copy files
```

## Note on Dependencies

Some proto files import `udpa/annotations/*` and `validate/validate.proto`. These are optional annotations used for validation and versioning. They won't break compilation if missing, but you may want to include them for full compatibility:

- `udpa` annotations: https://github.com/cncf/udpa
- `validate` annotations: https://github.com/envoyproxy/protoc-gen-validate
