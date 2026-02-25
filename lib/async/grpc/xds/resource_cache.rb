# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

module Async
	module GRPC
		module XDS
			# Caches discovered xDS resources
			# Thread-safe cache for clusters and endpoints
			class ResourceCache
				def initialize
					@clusters = {}
					@endpoints = {}
					@mutex = Mutex.new
				end
				
				# Get cluster by name
				# @parameter name [String] Cluster name
				# @returns [Resources::Cluster, nil] Cached cluster or nil
				def get_cluster(name)
					@mutex.synchronize{@clusters[name]}
				end
				
				# Update cluster in cache
				# @parameter cluster [Resources::Cluster] Cluster to cache
				def update_cluster(cluster)
					@mutex.synchronize{@clusters[cluster.name] = cluster}
				end
				
				# Get endpoints for cluster
				# @parameter cluster_name [String] Cluster name
				# @returns [Array<Async::HTTP::Endpoint>, nil] Cached endpoints or nil
				def get_endpoints(cluster_name)
					@mutex.synchronize{@endpoints[cluster_name]}
				end
				
				# Update endpoints for cluster
				# @parameter cluster_name [String] Cluster name
				# @parameter endpoints [Array<Async::HTTP::Endpoint>] Endpoints to cache
				def update_endpoints(cluster_name, endpoints)
					@mutex.synchronize{@endpoints[cluster_name] = endpoints}
				end
				
				# Clear all cached resources
				def clear
					@mutex.synchronize do
						@clusters.clear
						@endpoints.clear
					end
				end
			end
		end
	end
end
