# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.
# Copyright, 2026, by Alex Watt.

module Async
	module GRPC
		# Represents a generic async gRPC error.
		class Error < StandardError
		end
		
		# Raised when a gRPC call exceeds its deadline.
		class DeadlineExceededError < Error
		end
		
		# Raised when an HTTP response does not conform to gRPC.
		# Preserves the buffered response for inspection.
		class ResponseError < Error
			# Create an error from an invalid response, buffering its body for inspection.
			# @parameter response [Protocol::HTTP::Response] The invalid response.
			# @returns [ResponseError] The error with the buffered response attached.
			def self.for(response)
				self.new("Invalid gRPC response: HTTP #{response.status}, content-type #{response.headers["content-type"].to_s.inspect}!", response.buffered!)
			end
			
			# Initialize an error with a message and response.
			# @parameter message [String] The reason the response is invalid.
			# @parameter response [Protocol::HTTP::Response] The buffered response.
			def initialize(message, response)
				super(message)
				
				@response = response
			end
			
			# @attribute [Protocol::HTTP::Response] The buffered response, with its body available to read.
			attr :response
		end
		
		# Represents an error that originated from a remote gRPC server.
		# Used as the `cause` of {Protocol::GRPC::Error} when the client receives a non-OK status.
		# The message and optional backtrace are extracted from response metadata.
		class RemoteError < Error
			# Create a RemoteError from server response metadata.
			# @parameter message [String | Nil] The error message from `grpc-message` header.
			# @parameter metadata [Hash] Response metadata (extracted from gRPC headers). If it contains a `"backtrace"` key (array of strings), it is set on the error and removed from the hash.
			# @returns [RemoteError] The constructed error instance.
			def self.for(message, metadata)
				self.new(message).tap do |error|
					if backtrace = metadata.delete("backtrace")
						# Backtrace is always an array (Split header format):
						error.set_backtrace(backtrace)
					end
				end
			end
		end
	end
end
