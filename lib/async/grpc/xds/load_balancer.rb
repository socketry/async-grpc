# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async"
require "async/http/endpoint"
require_relative "health_checker"
require_relative "resources"

module Async
	module GRPC
		module XDS
			# Client-side load balancing with health checking.
			# RING_HASH and MAGLEV fall back to round-robin (require request context to hash).
			class LoadBalancer
				# Load balancing policies (matching Envoy cluster LB policies)
				ROUND_ROBIN = :round_robin
				LEAST_REQUEST = :least_request
				RANDOM = :random
				RING_HASH = :ring_hash
				MAGLEV = :maglev
				
				# Initialize load balancer
				# @parameter cluster [Resources::Cluster] Cluster configuration
				# @parameter endpoints [Array<Async::HTTP::Endpoint>] Initial endpoints
				def initialize(cluster, endpoints)
					@cluster = cluster
					@endpoints = endpoints
					@policy = parse_policy(cluster.lb_policy)
					@health_status = {}  # Track health per endpoint
					@health_checker = HealthChecker.new(cluster.health_checks)
					@current_index = 0
					@in_flight_requests = {}  # Track in-flight requests per endpoint
					@health_check_task = nil  # Transient task for health check loop
					
					# Initialize health status
					@endpoints.each do |ep|
						@health_status[ep] = :unknown
					end
					
					# Start health checking if configured
					start_health_checks if cluster.health_checks.any?
				end
				
				# Get healthy endpoints
				# @returns [Array<Async::HTTP::Endpoint>] Healthy endpoints
				def healthy_endpoints
					@endpoints.select{|ep| healthy?(ep)}
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
					old_endpoints = @endpoints
					@endpoints = endpoints
					
					# Update health checker
					@health_checker.update_endpoints(endpoints)
					
					# Initialize health status for new endpoints
					endpoints.each do |ep|
						@health_status[ep] ||= :unknown
					end
					
					# Remove state for old endpoints
					(old_endpoints - endpoints).each do |ep|
						@health_status.delete(ep)
						@in_flight_requests.delete(ep)
					end
				end
				
				# Record that a request has started for the given endpoint.
				# Used by LEAST_REQUEST policy. Call from Client when a call begins.
				# @parameter endpoint [Async::HTTP::Endpoint] The endpoint handling the request
				def record_request_start(endpoint)
					@in_flight_requests[endpoint] ||= 0
					@in_flight_requests[endpoint] += 1
				end
				
				# Record that a request has finished for the given endpoint.
				# Must be called in ensure to decrement even on error/retry.
				# @parameter endpoint [Async::HTTP::Endpoint] The endpoint that handled the request
				def record_request_end(endpoint)
					return unless endpoint
					current = @in_flight_requests[endpoint]
					return unless current && current > 0
					@in_flight_requests[endpoint] = current - 1
					@in_flight_requests.delete(endpoint) if @in_flight_requests[endpoint] == 0
				end
				
				# Mark endpoint as unhealthy (e.g. after connection failure).
				# Health checker may restore it on next successful check.
				# @parameter endpoint [Async::HTTP::Endpoint] The endpoint to mark unhealthy
				def mark_unhealthy(endpoint)
					@health_status[endpoint] = :unhealthy
				end
				
				# Close load balancer
				def close
					if health_check_task = @health_check_task
						@health_check_task = nil
						health_check_task.stop
					end
					
					@health_checker.close
				end
				
			private
				
				def healthy?(endpoint)
					status = @health_status[endpoint]
					status == :healthy || status == :unknown
				end
				
				def pick_round_robin(endpoints)
					@current_index = (@current_index + 1) % endpoints.size
					endpoints[@current_index]
				end
				
				def pick_least_request(endpoints)
					# Track in-flight requests and pick endpoint with fewest
					endpoints.min_by{|ep| @in_flight_requests[ep] || 0}
				end
				
				def pick_random(endpoints)
					endpoints.sample
				end
				
				def pick_ring_hash(endpoints)
					pick_round_robin(endpoints)  # Fallback; requires request context for consistent hashing
				end
				
				def pick_maglev(endpoints)
					pick_round_robin(endpoints)  # Fallback; requires request context for Maglev hashing
				end
				
				def parse_policy(lb_policy)
					# Parse cluster LB policy to our constants
					case lb_policy
					when :ROUND_ROBIN, "ROUND_ROBIN"
						ROUND_ROBIN
					when :LEAST_REQUEST, "LEAST_REQUEST"
						LEAST_REQUEST
					when :RANDOM, "RANDOM"
						RANDOM
					when :RING_HASH, "RING_HASH"
						RING_HASH
					when :MAGLEV, "MAGLEV"
						MAGLEV
					else
						ROUND_ROBIN  # Default
					end
				end
				
				def start_health_checks
					return unless @cluster.health_checks.any?
					
					@health_check_task = Async(transient: true) do
						loop do
							@endpoints.each do |endpoint|
								@health_status[endpoint] = @health_checker.check(endpoint)
							end
							
							# Sleep for health check interval
							interval = @cluster.health_checks.first[:interval] || 30
							sleep(interval)
						end
					end
				end
			end
		end
	end
end
