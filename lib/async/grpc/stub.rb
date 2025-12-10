# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "protocol/grpc/interface"

module Async
	module GRPC
		# Represents a client stub that provides method-based access to RPC calls.
		# Created by calling {Client#stub}.
		class Stub
			# Initialize a new stub instance.
			# @parameter client [Async::GRPC::Client] The gRPC client
			# @parameter interface [Protocol::GRPC::Interface] The interface instance
			def initialize(client, interface)
				@client = client
				@interface = interface
				@interface_class = interface.class
				# Cache RPCs indexed by snake_case method name (default)
				@rpcs_by_method = {}
				
				@interface_class.rpcs.each do |pascal_case_name, rpc|
					# rpc.method is always set (either explicit or auto-converted from PascalCase)
					snake_case_method = rpc.method
					
					# Index by snake_case method name, storing RPC and PascalCase name for path building
					@rpcs_by_method[snake_case_method] = [rpc, pascal_case_name]
				end
			end
			
			# @attribute [Protocol::GRPC::Interface] The interface instance.
			attr_reader :interface
			
			# Dynamically handle method calls for RPC methods.
			# Uses snake_case method names (Ruby convention).
			# @parameter method_name [Symbol] The method name to call (snake_case)
			# @parameter args [Array] Positional arguments (first is the request message)
			# @parameter options [Hash] Keyword arguments (metadata, timeout, encoding)
			# @yields {|input, output| ...} Block for streaming calls
			# @returns [Object | Protocol::GRPC::Body::ReadableBody] Response message or readable body
			# @raises [NoMethodError] If the method is not found
			def method_missing(method_name, *args, **options, &block)
				rpc, interface_method_name = lookup_rpc(method_name)
				
				if rpc
					# Extract request from args (first positional argument):
					request = args.first
					
					# Extract metadata, timeout, encoding from options:
					metadata = options.delete(:metadata) || {}
					timeout = options.delete(:timeout)
					encoding = options.delete(:encoding)
					
					# Delegate to client.invoke with PascalCase method name (for interface lookup):
					@client.invoke(@interface, interface_method_name, request, metadata: metadata, timeout: timeout, encoding: encoding,
						&block)
				else
					super
				end
			end
			
			# Check if the stub responds to the given method.
			# @parameter method_name [Symbol] The method name to check
			# @parameter include_private [Boolean] Whether to include private methods
			# @returns [Boolean] `true` if the method exists, `false` otherwise
			def respond_to_missing?(method_name, include_private = false)
				rpc, _ = lookup_rpc(method_name)
				return true if rpc
				
				super
			end
			
		private
			
			# Look up RPC definition for a method name.
			# @parameter method_name [Symbol] The method name to look up (snake_case)
			# @returns [Array(Protocol::GRPC::RPC, Symbol) | Array(Nil, Nil)] RPC definition and PascalCase method name, or nil if not found
			def lookup_rpc(method_name)
				if @rpcs_by_method.key?(method_name)
					rpc, pascal_case_name = @rpcs_by_method[method_name]
					return [rpc, pascal_case_name]
				end
				
				[nil, nil]
			end
		end
	end
end
