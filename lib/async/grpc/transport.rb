# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "socket"
require "openssl"
require "protocol/http/error"
require "protocol/http/body/wrapper"
require "protocol/grpc/error"

module Async
	module GRPC
		# Provides error translation at HTTP transport boundaries.
		module Transport
			ERRORS = [IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError, Protocol::HTTP::Error].freeze
			
			# Represents a response body that translates failures reading the transport.
			class Body < Protocol::HTTP::Body::Wrapper
				# Read raw response bytes, preserving transport failures as the cause.
				# @returns [String | Nil] The next chunk, or nil at end of stream.
				def read
					super
				rescue *ERRORS => error
					raise Protocol::GRPC::Unavailable.new(error.message), cause: error
				end
			end
		end
	end
end
