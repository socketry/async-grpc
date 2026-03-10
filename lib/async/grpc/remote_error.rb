# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

module Async
	module GRPC
		# Represents an error that originated from a remote gRPC server.
		# Used as the `cause` of {Protocol::GRPC::Error} when the client receives a non-OK status.
		# The message and optional backtrace are extracted from response metadata.
		class RemoteError < StandardError
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
