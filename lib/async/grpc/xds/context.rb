# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async"
require_relative "discovery_client"
require_relative "resource_cache"
require_relative "resources"

module Async
	module GRPC
		module XDS
			# Manages xDS subscriptions and maintains discovered resource state
			class Context
				# Raised when configuration is invalid
				class ConfigurationError < StandardError
				end
				
				# Raised when cluster configuration cannot be reloaded
				class ReloadError < StandardError
				end
				
				# Initialize xDS context
				# @parameter bootstrap [Hash] Bootstrap configuration
				# @parameter node [Hash] Node information (id, cluster, metadata, locality)
				def initialize(bootstrap, node: nil)
					@bootstrap = bootstrap
					xds_server = bootstrap[:xds_servers]&.first
					raise ConfigurationError, "No xds_servers in bootstrap" unless xds_server
					
					@discovery_client = DiscoveryClient.new(xds_server, node: node)
					@cache = ResourceCache.new
					@subscriptions = {}  # Track active subscriptions
					@load_balancer = nil  # Will be set by Client
					@mutex = Mutex.new
					@cluster_promises = {}  # service_name -> Async::Promise (level-triggered: resolved value persists)
					@endpoint_promises = {}  # cluster_name -> Async::Promise
				end
				
				# Set load balancer reference (called by Client)
				# @parameter load_balancer [LoadBalancer] Load balancer instance
				def load_balancer=(load_balancer)
					@load_balancer = load_balancer
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
						
						# Subscribe to EDS for same name up front (EDS clusters use service name as cluster name)
						# This avoids 10s delay between CDS and EDS - both requests go out together
						subscription_key = :"eds_#{service_name}"
						unless @subscriptions[subscription_key]
							@subscriptions[subscription_key] = subscribe_eds(service_name)
						end
					end
					return @cache.get_cluster(service_name) if @cache.get_cluster(service_name)
					
					# Wait for cluster (CDS response)
					cluster = wait_for_cluster(service_name, timeout: 10)
					raise ReloadError, "Failed to discover cluster: #{service_name}" unless cluster
					cluster
				end
				
				# Discover endpoints for cluster (like ClusterClient discovers nodes)
				# @parameter cluster [Resources::Cluster] Cluster configuration
				# @returns [Array<Async::HTTP::Endpoint>] Discovered endpoints
				def discover_endpoints(cluster)
					cluster_name = cluster.name
					@mutex.synchronize do
						# Check cache first
						if endpoints = @cache.get_endpoints(cluster_name)
							return endpoints
						end
						
						# Subscribe to EDS if not already subscribed
						subscription_key = :"eds_#{cluster_name}"
						unless @subscriptions[subscription_key]
							@subscriptions[subscription_key] = subscribe_eds(cluster_name)
						end
					end
					return @cache.get_endpoints(cluster_name) if @cache.get_endpoints(cluster_name)
					
					# Wait outside mutex so EDS callback can run and update cache
					endpoints = wait_for_endpoints(cluster_name, timeout: 10)
					raise ReloadError, "Failed to discover endpoints for cluster: #{cluster_name}" unless endpoints
					endpoints
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
							cluster = resource.is_a?(Resources::Cluster) ? resource : Resources::Cluster.from_proto(resource)
							@cache.update_cluster(cluster)
							resolve_cluster_promise(cluster.name, cluster)
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
							assignment = resource.is_a?(Resources::ClusterLoadAssignment) ? resource : Resources::ClusterLoadAssignment.from_proto(resource)
							endpoints = assignment.endpoints.select(&:healthy?).map do |ep|
								Async::HTTP::Endpoint.parse(ep.uri, protocol: Async::HTTP::Protocol::HTTP2)
							end
							@cache.update_endpoints(cluster_name, endpoints)
							resolve_endpoint_promise(cluster_name, endpoints) unless endpoints.empty?
							@load_balancer&.update_endpoints(endpoints)
						end
					end
				end
				
				# Close all subscriptions
				def close
					@mutex.synchronize do
						@subscriptions.each_value do |task|
							task.stop if task.respond_to?(:stop)
						end
						@subscriptions.clear
						@cluster_promises.clear
						@endpoint_promises.clear
					end
					@discovery_client.close
				end
				
				private
				
				def wait_for_cluster(service_name, timeout:)
					promise = cluster_promise_for(service_name)
					return promise.value if promise.completed?
					
					begin
						promise.wait(timeout: timeout)
						promise.completed? ? promise.value : nil
					rescue Async::TimeoutError
						nil
					end
				end
				
				def wait_for_endpoints(cluster_name, timeout:)
					promise = endpoint_promise_for(cluster_name)
					return promise.value if promise.completed?
					
					begin
						promise.wait(timeout: timeout)
						promise.completed? ? promise.value : nil
					rescue Async::TimeoutError
						nil
					end
				end
				
				def cluster_promise_for(service_name)
					@mutex.synchronize do
						@cluster_promises[service_name] ||= Async::Promise.new
					end
				end
				
				def endpoint_promise_for(cluster_name)
					@mutex.synchronize do
						@endpoint_promises[cluster_name] ||= Async::Promise.new
					end
				end
				
				def resolve_cluster_promise(service_name, cluster)
					cluster_promise_for(service_name).resolve(cluster)
					@mutex.synchronize{@cluster_promises.delete(service_name)}
				end
				
				def resolve_endpoint_promise(cluster_name, endpoints)
					endpoint_promise_for(cluster_name).resolve(endpoints)
					@mutex.synchronize{@endpoint_promises.delete(cluster_name)}
				end
			end
		end
	end
end
