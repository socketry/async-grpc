# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

module Async
	module GRPC
		# Raised when a gRPC call exceeds its deadline.
		class DeadlineExceeded < StandardError
		end
	end
end
