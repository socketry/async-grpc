# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

module Async
	module GRPC
		module XDS
			module Resources
				# Represents a discovered cluster
				# Based on envoy.config.cluster.v3.Cluster
				class Cluster
					attr_reader :name, :type, :lb_policy, :health_checks, :circuit_breakers, :eds_cluster_config
					
					# Initialize cluster from protobuf or hash
					# @parameter data [Object, Hash] Cluster protobuf or hash representation
					def initialize(data)
						if data.is_a?(Hash)
							@name = data[:name]
							@type = parse_type(data[:type])
							@lb_policy = parse_lb_policy(data[:lb_policy])
							@health_checks = parse_health_checks(data[:health_checks] || [])
							@circuit_breakers = data[:circuit_breakers]
							@eds_cluster_config = data[:eds_cluster_config]
						else
							# Assume protobuf object
							@name = data.name
							@type = parse_type(data.type)
							@lb_policy = parse_lb_policy(data.lb_policy)
							@health_checks = parse_health_checks(data.health_checks || [])
							@circuit_breakers = data.circuit_breakers
							@eds_cluster_config = data.eds_cluster_config
						end
					end
					
					# Create Cluster from protobuf message
					# @parameter proto [Envoy::Config::Cluster::V3::Cluster] Protobuf cluster
					# @returns [Cluster] Cluster instance
					def self.from_proto(proto)
						new(proto)
					end
					
					def eds_cluster?
						@type == :EDS
					end
					
					private
					
					def parse_type(type)
						# Handle protobuf enum values (integers) or symbols/strings
						case type
						when :EDS, "EDS", "envoy.config.cluster.v3.Cluster.EDS", 3
							:EDS
						when :STATIC, "STATIC", "envoy.config.cluster.v3.Cluster.STATIC", 0
							:STATIC
						when :LOGICAL_DNS, "LOGICAL_DNS", "envoy.config.cluster.v3.Cluster.LOGICAL_DNS", 2
							:LOGICAL_DNS
						when :STRICT_DNS, "STRICT_DNS", "envoy.config.cluster.v3.Cluster.STRICT_DNS", 1
							:STRICT_DNS
						else
							# Default to EDS for unknown types
							:EDS
						end
					end
					
					def parse_lb_policy(policy)
						# Handle protobuf enum values (integers) or symbols/strings
						case policy
						when :ROUND_ROBIN, "ROUND_ROBIN", "envoy.config.cluster.v3.Cluster.ROUND_ROBIN", 0
							:ROUND_ROBIN
						when :LEAST_REQUEST, "LEAST_REQUEST", "envoy.config.cluster.v3.Cluster.LEAST_REQUEST", 1
							:LEAST_REQUEST
						when :RANDOM, "RANDOM", "envoy.config.cluster.v3.Cluster.RANDOM", 3
							:RANDOM
						when :RING_HASH, "RING_HASH", "envoy.config.cluster.v3.Cluster.RING_HASH", 2
							:RING_HASH
						when :MAGLEV, "MAGLEV", "envoy.config.cluster.v3.Cluster.MAGLEV", 5
							:MAGLEV
						else
							# Default to ROUND_ROBIN
							:ROUND_ROBIN
						end
					end
					
					def parse_health_checks(checks)
						Array(checks).map do |check|
							if check.is_a?(Hash)
								{
									type: parse_health_check_type(check[:health_checker] || check[:type] || :HTTP),
									timeout: parse_duration(check[:timeout]),
									interval: parse_duration(check[:interval] || 30),
									path: extract_http_path(check)
								}
							else
								# Protobuf HealthCheck object
								{
									type: parse_health_check_type(check.health_checker),
									timeout: parse_duration(check.timeout),
									interval: parse_duration(check.interval),
									path: extract_http_path_from_proto(check)
								}
							end
						end
					end
					
					def parse_health_check_type(checker)
						# Handle protobuf HealthCheck.health_checker oneof
						# checker is the health_checker field from HealthCheck protobuf
						return :HTTP if checker.nil?
						
						case checker
						when Hash
							checker_type = checker[:type]
							case checker_type
							when :HTTP, "HTTP", "envoy.config.core.v3.HealthCheck.HttpHealthCheck"
								:HTTP
							when :gRPC, "gRPC", "envoy.config.core.v3.HealthCheck.GrpcHealthCheck"
								:gRPC
							when :TCP, "TCP", "envoy.config.core.v3.HealthCheck.TcpHealthCheck"
								:TCP
							else
								:HTTP  # Default
							end
						else
							# Protobuf HealthCheck object - check which oneof field is set
							# The health_checker is a oneof, so we check which field is populated
							if checker.respond_to?(:http_health_check) && checker.http_health_check
								:HTTP
							elsif checker.respond_to?(:grpc_health_check) && checker.grpc_health_check
								:gRPC
							elsif checker.respond_to?(:tcp_health_check) && checker.tcp_health_check
								:TCP
							else
								:HTTP  # Default
							end
						end
					end
					
					def parse_duration(duration)
						# Convert protobuf Duration to seconds (float)
						return duration if duration.is_a?(Numeric)
						return nil unless duration
						
						# If it's a protobuf Duration, convert to seconds
						if duration.respond_to?(:seconds) && duration.respond_to?(:nanos)
							duration.seconds + (duration.nanos.to_f / 1_000_000_000)
						else
							duration.to_f
						end
					end
					
					def extract_http_path(check)
						# Extract HTTP path from hash
						return nil unless check.is_a?(Hash)
						
						http_check = check[:http_health_check] || {}
						http_check[:path] || "/health"
					end
					
					def extract_http_path_from_proto(check)
						# Extract HTTP path from protobuf HealthCheck
						return nil unless check.respond_to?(:http_health_check)
						
						http_check = check.http_health_check
						return nil unless http_check
						
						http_check.path || "/health"
					end
				end
				
				# Represents endpoint assignment (ClusterLoadAssignment)
				# Based on envoy.config.endpoint.v3.ClusterLoadAssignment
				class ClusterLoadAssignment
					attr_reader :cluster_name, :endpoints
					
					# Initialize from protobuf or hash
					# @parameter data [Object, Hash] ClusterLoadAssignment protobuf or hash
					def initialize(data)
						if data.is_a?(Hash)
							@cluster_name = data[:cluster_name]
							@endpoints = parse_endpoints(data[:endpoints] || [])
						else
							@cluster_name = data.cluster_name
							@endpoints = parse_endpoints(data.endpoints || [])
						end
					end
					
					# Create ClusterLoadAssignment from protobuf message
					# @parameter proto [Envoy::Config::Endpoint::V3::ClusterLoadAssignment] Protobuf assignment
					# @returns [ClusterLoadAssignment] Assignment instance
					def self.from_proto(proto)
						new(proto)
					end
					
					private
					
					def parse_endpoints(endpoints_data)
						Array(endpoints_data).flat_map do |locality_endpoints|
							lb_endpoints = locality_endpoints.is_a?(Hash) ?
								(locality_endpoints[:lb_endpoints] || []) :
								(locality_endpoints.lb_endpoints || [])
							
							lb_endpoints.map{|lb_ep| Endpoint.new(lb_ep)}
						end
					end
				end
				
				# Represents a single endpoint
				# Based on envoy.config.endpoint.v3.LbEndpoint
				class Endpoint
					attr_reader :address, :port, :health_status, :metadata
					
					def initialize(lb_endpoint)
						if lb_endpoint.is_a?(Hash)
							endpoint_data = lb_endpoint[:endpoint] || {}
							address_data = endpoint_data[:address] || {}
							socket_address = address_data[:socket_address] || {}
							
							@address = socket_address[:address] || "localhost"
							@port = socket_address[:port_value] || 50051
							@health_status = parse_health_status(lb_endpoint[:health_status])
							@metadata = lb_endpoint[:metadata] || {}
						else
							socket_address = lb_endpoint.endpoint.address.socket_address
							@address = socket_address.address
							@port = socket_address.port_value
							@health_status = parse_health_status(lb_endpoint.health_status)
							@metadata = lb_endpoint.metadata || {}
						end
					end
					
					def healthy?
						@health_status == :HEALTHY || @health_status == :UNKNOWN
					end
					
					def uri
						# Use http for insecure/docker environments (gRPC h2c)
						scheme = ENV["XDS_ENDPOINT_SCHEME"] || "http"
						"#{scheme}://#{@address}:#{@port}"
					end
					
					private
					
					def parse_health_status(status)
						# Handle protobuf enum values (integers) or symbols/strings
						# HealthStatus is defined in envoy.config.endpoint.v3.Endpoint
						case status
						when :HEALTHY, "HEALTHY", 0
							:HEALTHY
						when :UNHEALTHY, "UNHEALTHY", 1
							:UNHEALTHY
						when :DEGRADED, "DEGRADED", 2
							:DEGRADED
						when :UNKNOWN, "UNKNOWN", 3, nil
							:UNKNOWN
						else
							# Try to match against protobuf enum if available
							begin
								require "envoy/config/endpoint/v3/endpoint_pb"
								case status
								when Envoy::Config::Endpoint::V3::Endpoint::HealthStatus::HEALTHY
									:HEALTHY
								when Envoy::Config::Endpoint::V3::Endpoint::HealthStatus::UNHEALTHY
									:UNHEALTHY
								when Envoy::Config::Endpoint::V3::Endpoint::HealthStatus::DEGRADED
									:DEGRADED
								when Envoy::Config::Endpoint::V3::Endpoint::HealthStatus::UNKNOWN
									:UNKNOWN
								else
									:UNKNOWN
								end
							rescue NameError, LoadError
								:UNKNOWN
							end
						end
					end
				end
			end
		end
	end
end
