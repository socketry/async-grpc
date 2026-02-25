# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async"
require "async/http/client"
require "async/http/endpoint"
require "protocol/http"

module Async
	module GRPC
		module XDS
			# Performs health checks on endpoints. Called by LoadBalancer's loop.
			# Runs within the caller's reactor; does not spawn tasks or reactors.
			# Only HTTP health checks are supported; gRPC health checks return :unknown.
			class HealthChecker
				# Initialize health checker
				# @parameter health_checks [Array<Hash>] Health check configurations from cluster
				def initialize(health_checks)
					@health_checks = health_checks
					@endpoints = []
					@cache = {}
				end
				
				# Update endpoints (cleans cache for removed endpoints)
				# @parameter endpoints [Array<Async::HTTP::Endpoint>] Current endpoints
				def update_endpoints(endpoints)
					removed = @endpoints - endpoints
					removed.each{|ep| @cache.delete(ep)}
					@endpoints = endpoints
				end
				
				# Check health of endpoint. Runs in caller's reactor.
				# @parameter endpoint [Async::HTTP::Endpoint] Endpoint to check
				# @returns [Symbol] :healthy, :unhealthy, or :unknown
				def check(endpoint)
					if cached = @cache[endpoint]
						return cached[:status] if Time.now - cached[:time] < 5
					end
					
					status = perform_check(endpoint)
					@cache[endpoint] = {status: status, time: Time.now}
					status
				end
				
				# Close health checker
				def close
					@cache.clear
				end
				
			private
				
				def perform_check(endpoint)
					health_check = @health_checks.first
					return :unknown unless health_check
					
					case health_check[:type]
					when :HTTP, "HTTP"
						check_http_health(endpoint, health_check)
					when :gRPC, "gRPC"
						check_grpc_health(endpoint, health_check)
					else
						:unknown
					end
				rescue => error
					Console.warn(self, "Health check failed for #{endpoint}: #{error.message}")
					:unhealthy
				end
				
				def check_http_health(endpoint, health_check)
					path = health_check[:path] || "/health"
					http_client = Async::HTTP::Client.new(endpoint)
					request = Protocol::HTTP::Request["GET", path]
					response = http_client.call(request)
					response.status == 200 ? :healthy : :unhealthy
				ensure
					http_client&.close
				end
				
				def check_grpc_health(endpoint, health_check)
					# gRPC health checks (grpc.health.v1.Health) not implemented
					:unknown
				end
			end
		end
	end
end
