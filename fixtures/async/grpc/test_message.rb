# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

module Protocol
	module GRPC
		module Fixtures
			# Simple test message for unit tests.
			# Provides a basic protobuf-like message structure.
			class TestMessage
				# @attribute [String | Nil] The message value.
				attr_accessor :value
				
				# Initialize a new test message.
				# @parameter value [String | Nil] The message value
				def initialize(value: nil)
					@value = value
				end
				
				# Serialize the message to a binary string.
				# @returns [String] Binary representation of the message
				def to_proto
					# Simple serialization: length-prefixed value
					value_data = (@value || "").dup.force_encoding(Encoding::BINARY)
					[value_data.bytesize].pack("N") + value_data
				end
				
				alias encode to_proto
				
				# Deserialize a binary string into a message.
				# @parameter data [String] Binary representation of the message
				# @returns [TestMessage] Deserialized message instance
				def self.decode(data)
					# Simple binary format: first 4 bytes are length, rest is value
					length = data[0...4].unpack1("N")
					value = data[4...(4 + length)].dup.force_encoding(Encoding::UTF_8)
					new(value: value)
				end
				
				# Check equality with another message.
				# @parameter other [Object] The object to compare
				# @returns [Boolean] `true` if values are equal
				def ==(other)
					other.is_a?(TestMessage) && @value == other.value
				end
				
				# Get a string representation of the message.
				# @returns [String] String representation
				def inspect
					"#<#{self.class.name} value=#{@value.inspect}>"
				end
			end
		end
	end
end

