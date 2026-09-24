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
		# Preserves the response body in the error message and the response for inspection.
		class ResponseError < Error
			# Initialize an error by reading the raw response body.
			# @parameter response [Protocol::HTTP::Response] The invalid response.
			def initialize(response)
				super(response.read)
				
				@response = response
			end
			
			# @attribute [Protocol::HTTP::Response] The response, with its body consumed.
			attr :response
			
			# Describe the invalid response and include its body.
			# @returns [String] The HTTP status, content type, and response body.
			def to_s
				"Invalid gRPC response: HTTP #{@response.status}, content-type #{@response.headers["content-type"].to_s.inspect}!\n#{super}"
			end
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
