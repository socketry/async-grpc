# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

module Async
	module GRPC
		class RemoteError < StandardError
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
