# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

# Envoy protobuf definitions for xDS support
# Generated from envoyproxy/data-plane-api
#
# This module provides access to generated Envoy protobuf classes for xDS.
# Files are generated using protoc from .proto files in the proto/ directory.

# Core discovery service (most important for xDS)
# Note: Generated protobuf files use absolute requires, so lib must be in $LOAD_PATH
# Load dependencies first (in order)
# XDS annotations
require "xds/annotations/v3/status_pb"
require "xds/core/v3/context_params_pb"
require "xds/core/v3/authority_pb"

# UDPA annotations
require "udpa/annotations/status_pb"
require "udpa/annotations/versioning_pb"
require "udpa/annotations/migrate_pb"

# Validate annotations
require "validate/validate_pb"

# Envoy annotations
require "envoy/annotations/deprecation_pb"

# Envoy type definitions
require "envoy/type/v3/percent_pb"
require "envoy/type/v3/semantic_version_pb"

# Envoy config core (load in dependency order)
require "envoy/config/core/v3/extension_pb"
require "envoy/config/core/v3/backoff_pb"
require "envoy/config/core/v3/http_uri_pb"
require "envoy/config/core/v3/grpc_service_pb"
require "envoy/config/core/v3/address_pb"
require "envoy/config/core/v3/base_pb"
require "envoy/config/core/v3/config_source_pb"

# Discovery service
require "envoy/service/discovery/v3/discovery_pb"
require "envoy/service/discovery/v3/ads_pb"
require "envoy/service/discovery/v3/aggregated_discovery_service"

# Resource types
require "envoy/config/cluster/v3/cluster_pb"
require "envoy/config/endpoint/v3/endpoint_pb"

module Envoy
	module Service
		module Discovery
			module V3
				# Re-export for convenience
				# Use Envoy::Service::Discovery::V3::DiscoveryRequest
				# Use Envoy::Service::Discovery::V3::AggregatedDiscoveryService
			end
		end
	end
	
	module Config
		module Cluster
			module V3
				# Use Envoy::Config::Cluster::V3::Cluster
			end
		end
		
		module Endpoint
			module V3
				# Use Envoy::Config::Endpoint::V3::ClusterLoadAssignment
			end
		end
		
		module Core
			module V3
				# Use Envoy::Config::Core::V3::Node
			end
		end
	end
end
