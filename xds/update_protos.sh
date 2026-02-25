#!/bin/bash
# Update Envoy protobuf definitions
# This script clones the envoy data-plane-api and copies only the needed .proto files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROTO_DIR="$PROJECT_ROOT/proto"
TEMP_DIR="/tmp/envoy-api-$$"

echo "Cloning envoyproxy/data-plane-api..."

# Clone with sparse checkout to only get what we need
git clone --depth 1 --filter=blob:none --sparse https://github.com/envoyproxy/data-plane-api.git "$TEMP_DIR"

cd "$TEMP_DIR"

echo "Setting up sparse checkout..."

# First get envoy config files
git sparse-checkout set \
  envoy/config/cluster/v3 \
  envoy/config/endpoint/v3 \
  envoy/config/listener/v3 \
  envoy/config/route/v3 \
  envoy/config/core/v3 \
  envoy/extensions/transport_sockets/tls/v3

# Copy envoy config files
cp -r envoy "$PROTO_DIR/"

# Now get discovery service and google protobuf files
git sparse-checkout set \
  envoy/service/discovery/v3 \
  google/protobuf

# Copy discovery service
cp -r envoy/service "$PROTO_DIR/envoy/"

# Copy google protobuf (if exists in repo)
if [ -d "google" ]; then
	cp -r google "$PROTO_DIR/"
fi

# Get Google protobuf well-known types from protobuf repo
echo "Fetching Google protobuf well-known types..."
git clone --depth 1 https://github.com/protocolbuffers/protobuf.git /tmp/protobuf-$$
mkdir -p "$PROTO_DIR/google/protobuf"
cp /tmp/protobuf-$$/src/google/protobuf/{any,duration,timestamp,struct,empty,wrappers}.proto "$PROTO_DIR/google/protobuf/" 2>/dev/null || true
rm -rf /tmp/protobuf-$$

# Get google/rpc/status.proto from api-common-protos
echo "Fetching google/rpc/status.proto..."
git clone --depth 1 https://github.com/googleapis/api-common-protos.git /tmp/api-common-$$
mkdir -p "$PROTO_DIR/google/rpc"
cp /tmp/api-common-$$/google/rpc/status.proto "$PROTO_DIR/google/rpc/" 2>/dev/null || true
rm -rf /tmp/api-common-$$

# Get envoy/type/v3 and xds/core/v3 from data-plane-api
echo "Fetching envoy/type/v3 and xds/core/v3..."
git clone --depth 1 --filter=blob:none --sparse https://github.com/envoyproxy/data-plane-api.git /tmp/envoy-types-$$
cd /tmp/envoy-types-$$
git sparse-checkout set envoy/type/v3 envoy/type/matcher/v3 envoy/type/metadata/v3 xds/core/v3
mkdir -p "$PROTO_DIR/envoy/type/v3" "$PROTO_DIR/envoy/type/matcher/v3" "$PROTO_DIR/envoy/type/metadata/v3" "$PROTO_DIR/xds/core/v3"
cp -r envoy/type "$PROTO_DIR/envoy/" 2>/dev/null || true
cp -r xds/core "$PROTO_DIR/xds/" 2>/dev/null || true
rm -rf /tmp/envoy-types-$$

# Get xds/type/matcher/v3 and xds/core/v3 from cncf/xds repo
echo "Fetching xds/type/matcher/v3 and xds/core/v3..."
git clone --depth 1 https://github.com/cncf/xds.git /tmp/xds-types-$$
mkdir -p "$PROTO_DIR/xds/type/matcher/v3" "$PROTO_DIR/xds/core/v3"
find /tmp/xds-types-$$/xds/type/matcher/v3 -name "*.proto" ! -name "*cel*" -exec cp {} "$PROTO_DIR/xds/type/matcher/v3/" \;
find /tmp/xds-types-$$/xds/core/v3 -name "*.proto" -exec cp {} "$PROTO_DIR/xds/core/v3/" \;
rm -rf /tmp/xds-types-$$

# Get udpa annotations
echo "Fetching udpa annotations..."
git clone --depth 1 https://github.com/cncf/udpa.git /tmp/udpa-$$
mkdir -p "$PROTO_DIR/udpa/annotations"
cp /tmp/udpa-$$/udpa/annotations/*.proto "$PROTO_DIR/udpa/annotations/" 2>/dev/null || true
rm -rf /tmp/udpa-$$

# Get validate annotations
echo "Fetching validate annotations..."
git clone --depth 1 https://github.com/envoyproxy/protoc-gen-validate.git /tmp/validate-$$
mkdir -p "$PROTO_DIR/validate"
cp /tmp/validate-$$/validate/validate.proto "$PROTO_DIR/validate/" 2>/dev/null || true
rm -rf /tmp/validate-$$

# Get envoy annotations
echo "Fetching envoy annotations..."
git clone --depth 1 --filter=blob:none --sparse https://github.com/envoyproxy/envoy.git /tmp/envoy-annotations-$$
cd /tmp/envoy-annotations-$$
git sparse-checkout set api/envoy/annotations
mkdir -p "$PROTO_DIR/envoy/annotations"
cp api/envoy/annotations/*.proto "$PROTO_DIR/envoy/annotations/" 2>/dev/null || true
rm -rf /tmp/envoy-annotations-$$

echo "Copying .proto files to $PROTO_DIR..."

# Create directories
mkdir -p "$PROTO_DIR/envoy/service/discovery/v3"
mkdir -p "$PROTO_DIR/envoy/config/cluster/v3"
mkdir -p "$PROTO_DIR/envoy/config/endpoint/v3"
mkdir -p "$PROTO_DIR/envoy/config/listener/v3"
mkdir -p "$PROTO_DIR/envoy/config/route/v3"
mkdir -p "$PROTO_DIR/envoy/config/core/v3"
mkdir -p "$PROTO_DIR/envoy/extensions/transport_sockets/tls/v3"
mkdir -p "$PROTO_DIR/google/protobuf"

# Copy files
cp -r envoy "$PROTO_DIR/"
cp -r google "$PROTO_DIR/"

# Cleanup
rm -rf "$TEMP_DIR"

echo "Done! Proto files updated in $PROTO_DIR"
echo ""
echo "To generate Ruby code, run:"
echo "  bundle exec bake async:grpc:xds:generate_protos"
