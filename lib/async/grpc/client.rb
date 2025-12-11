# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "async"
require "async/http/client"
require "async/http/endpoint"

require "protocol/http"
require "protocol/grpc"
require "protocol/grpc/interface"
require "protocol/grpc/methods"
require "protocol/grpc/body/readable_body"
require "protocol/grpc/body/writable_body"
require "protocol/grpc/metadata"
require "protocol/grpc/error"
require_relative "stub"

module Async
	module GRPC
		# Represents a client for making gRPC calls over HTTP/2.
		class Client < Protocol::HTTP::Middleware
			ENDPOINT = nil
			
			# Connect to the given endpoint, returning the HTTP client.
			# @parameter endpoint [Async::HTTP::Endpoint] used to connect to the remote system.
			# @returns [Async::HTTP::Client] the HTTP client.
			def self.connect(endpoint)
				HTTP::Client.new(endpoint)
			end
			
			# Create a new client for the given endpoint.
			# @parameter endpoint [Async::HTTP::Endpoint, String] The endpoint to connect to
			# @parameter headers [Protocol::HTTP::Headers] Default headers to include with requests
			# @yields {|client| ...} Optional block - client will be closed after block execution
			# @returns [Client] The client instance
			def self.open(endpoint = self::ENDPOINT, headers: Protocol::HTTP::Headers.new, **options)
				endpoint = Async::HTTP::Endpoint.parse(endpoint) if endpoint.is_a?(String)
				
				client = connect(endpoint)
				
				grpc_client = new(client, headers: headers, **options)
				
				return grpc_client unless block_given?
				
				Sync do
					yield grpc_client
				ensure
					grpc_client.close
				end
			end
			
			# Create a new client with merged headers from a parent client.
			# @parameter parent [Client] The parent client to inherit headers from
			# @parameter headers [Hash] Additional headers to merge
			# @returns [Client] A new client instance with merged headers
			def self.with(parent, headers: {})
				merged_headers = parent.headers.merge(headers)
				
				new(parent.delegate, headers: merged_headers)
			end
			
			# Initialize a new gRPC client.
			# @parameter delegate [Async::HTTP::Client] The HTTP client that will handle requests
			# @parameter headers [Protocol::HTTP::Headers] The default headers that will be supplied with requests
			def initialize(delegate, headers: Protocol::HTTP::Headers.new)
				super(delegate)
				
				@headers = headers
			end
			
			# @attribute [Protocol::HTTP::Headers] The default headers for requests.
			attr_reader :headers
			
			# Get a string representation of the client.
			# @returns [String] A string representation including headers
			def inspect
				"\#<#{self.class} #{@headers.inspect}>"
			end
			
			# Get a string representation of the client.
			# @returns [String] A string representation of the client class
			def to_s
				"\#<#{self.class}>"
			end
			
			# Create a stub for the given interface.
			# @parameter interface_class [Class] Interface class (subclass of Protocol::GRPC::Interface)
			# @parameter service_name [String] Service name (e.g., "hello.Greeter")
			# @returns [Async::GRPC::Stub] Stub object with methods for each RPC
			def stub(interface_class, service_name)
				interface = interface_class.new(service_name)
				Stub.new(self, interface)
			end
			
			# Call the underlying HTTP client with merged headers.
			# @parameter request [Protocol::HTTP::Request] The HTTP request
			# @returns [Protocol::HTTP::Response] The HTTP response
			def call(request)
				request.headers = @headers.merge(request.headers)
				
				super.tap do |response|
					response.headers.policy = Protocol::GRPC::HEADER_POLICY
				end
			end
			
			# Make a gRPC call.
			# @parameter service [Protocol::GRPC::Interface] Interface definition
			# @parameter method [Symbol, String] Method name
			# @parameter request [Object | Nil] Request message (`Nil` for streaming)
			# @parameter metadata [Hash] Custom metadata headers
			# @parameter timeout [Numeric | Nil] Optional timeout in seconds
			# @parameter encoding [String | Nil] Optional compression encoding
			# @yields {|input, output| ...} Block for streaming calls
			# @returns [Object | Protocol::GRPC::Body::ReadableBody] Response message or readable body for streaming
			# @raises [ArgumentError] If method is unknown or streaming type is invalid
			# @raises [Protocol::GRPC::Error] If the gRPC call fails
			def invoke(service, method, request = nil, metadata: {}, timeout: nil, encoding: nil, &block)
				rpc = service.class.lookup_rpc(method)
				raise ArgumentError, "Unknown method: #{method}" unless rpc
				
				path = service.path(method)
				headers = Protocol::GRPC::Methods.build_headers(
					metadata: metadata,
					timeout: timeout,
					content_type: "application/grpc+proto"
				)
				headers["grpc-encoding"] = encoding if encoding
				
				streaming = rpc.streaming
				request_class = rpc.request_class
				response_class = rpc.response_class
				
				case streaming
				when :unary
					unary_call(path, headers, request, request_class, response_class, encoding)
				when :server_streaming
					server_streaming_call(path, headers, request, request_class, response_class, encoding, &block)
				when :client_streaming
					client_streaming_call(path, headers, request_class, response_class, encoding, &block)
				when :bidirectional
					bidirectional_call(path, headers, request_class, response_class, encoding, &block)
				else
					raise ArgumentError, "Unknown streaming type: #{streaming}"
				end
			end
			
		protected
			
			# Make a unary gRPC call.
			# @parameter path [String] The gRPC path
			# @parameter headers [Protocol::HTTP::Headers] Request headers
			# @parameter request_message [Object] Request message
			# @parameter request_class [Class] Request message class
			# @parameter response_class [Class] Response message class
			# @parameter encoding [String | Nil] Compression encoding
			# @returns [Object] Response message
			# @raises [Protocol::GRPC::Error] If the gRPC call fails
			def unary_call(path, headers, request_message, request_class, response_class, encoding)
				body = Protocol::GRPC::Body::WritableBody.new(encoding: encoding, message_class: request_class)
				body.write(request_message)
				body.close_write
				
				http_request = Protocol::HTTP::Request["POST", path, headers, body]
				response = call(http_request)
				
				begin
					# Read body first - trailers are only available after body is consumed
					response_encoding = response.headers["grpc-encoding"]
					response_body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: response_class, encoding: response_encoding)
					
					if response_body
						response_value = response_body.read
						response_body.close
					end
					
					# Check status after reading body (trailers are now available)
					check_status!(response)
					
					return response_value
				ensure
					response.close
				end
			end
			
			# Make a server streaming gRPC call.
			# @parameter path [String] The gRPC path
			# @parameter headers [Protocol::HTTP::Headers] Request headers
			# @parameter request_message [Object] Request message
			# @parameter request_class [Class] Request message class
			# @parameter response_class [Class] Response message class
			# @parameter encoding [String | Nil] Compression encoding
			# @yields {|message| ...} Block to process each message in the stream
			# @returns [Protocol::GRPC::Body::ReadableBody] Readable body for streaming messages
			# @raises [Protocol::GRPC::Error] If the gRPC call fails
			def server_streaming_call(path, headers, request_message, request_class, response_class, encoding, &block)
				body = Protocol::GRPC::Body::WritableBody.new(encoding: encoding, message_class: request_class)
				body.write(request_message)
				body.close_write
				
				http_request = Protocol::HTTP::Request["POST", path, headers, body]
				response = call(http_request)
				
				begin
					# Read body first - trailers are only available after body is consumed:
					response_encoding = response.headers["grpc-encoding"]
					response_body = Protocol::GRPC::Body::ReadableBody.wrap(response, message_class: response_class, encoding: response_encoding)
					
					if block_given? and response_body
						response_body.each(&block)
					end
					
					# Check status after reading all body chunks (trailers are now available):
					check_status!(response)
					
					return response_body
				rescue
					response.close
					raise
				end
			end
			
			# Make a client streaming gRPC call.
			# @parameter path [String] The gRPC path
			# @parameter headers [Protocol::HTTP::Headers] Request headers
			# @parameter request_class [Class] Request message class
			# @parameter response_class [Class] Response message class
			# @parameter encoding [String | Nil] Compression encoding
			# @yields {|output| ...} Block to write messages to the stream
			# @returns [Object] Response message
			# @raises [Protocol::GRPC::Error] If the gRPC call fails
			def client_streaming_call(path, headers, request_class, response_class, encoding, &block)
				body = Protocol::GRPC::Body::WritableBody.new(encoding: encoding, message_class: request_class)
				
				http_request = Protocol::HTTP::Request["POST", path, headers, body]
				
				block.call(body) if block_given?
				body.close_write unless body.closed?
				
				response = call(http_request)
				
				begin
					# Read body first - trailers are only available after body is consumed:
					response_encoding = response.headers["grpc-encoding"]
					readable_body = Protocol::GRPC::Body::ReadableBody.new(
						response.body,
						message_class: response_class,
						encoding: response_encoding
					)
					
					message = readable_body.read
					readable_body.close
					
					# Check status after reading body (trailers are now available):
					check_status!(response)
					
					message
				ensure
					response.close
				end
			end
			
			# Make a bidirectional streaming gRPC call.
			# @parameter path [String] The gRPC path
			# @parameter headers [Protocol::HTTP::Headers] Request headers
			# @parameter request_class [Class] Request message class
			# @parameter response_class [Class] Response message class
			# @parameter encoding [String | Nil] Compression encoding
			# @yields {|input, output| ...} Block to handle bidirectional streaming
			# @returns [Protocol::GRPC::Body::ReadableBody] Readable body for streaming messages
			# @raises [Protocol::GRPC::Error] If the gRPC call fails
			def bidirectional_call(path, headers, request_class, response_class, encoding, &block)
				body = Protocol::GRPC::Body::WritableBody.new(
					encoding: encoding,
					message_class: request_class
				)
				
				http_request = Protocol::HTTP::Request["POST", path, headers, body]
				response = call(http_request)
				
				begin
					# Read body first - trailers are only available after body is consumed:
					response_encoding = response.headers["grpc-encoding"]
					readable_body = Protocol::GRPC::Body::ReadableBody.new(
						response.body,
						message_class: response_class,
						encoding: response_encoding
					)
					
					return readable_body unless block_given?
					
					begin
						block.call(readable_body, body)
						body.close_write unless body.closed?
						
						# Consume all response chunks to ensure trailers are available:
						readable_body.each{|_|}
					ensure
						readable_body.close
					end
					
					# Check status after reading all body chunks (trailers are now available):
					check_status!(response)
					
					readable_body
				rescue StandardError
					response.close
					raise
				end
			end
			
			# Check gRPC status and raise appropriate error if not OK.
			# @parameter response [Protocol::HTTP::Response]
			# @raises [Protocol::GRPC::Error] If status is not OK
			def check_status!(response)
				status = Protocol::GRPC::Metadata.extract_status(response.headers)
				
				# If status is UNKNOWN (not found), default to OK:
				# This handles cases where trailers aren't available or status wasn't set
				status = Protocol::GRPC::Status::OK if status == Protocol::GRPC::Status::UNKNOWN
				
				return if status == Protocol::GRPC::Status::OK
				
				message = Protocol::GRPC::Metadata.extract_message(response.headers)
				metadata = Protocol::GRPC::Methods.extract_metadata(response.headers)
				
				raise Protocol::GRPC::Error.for(status, message, metadata: metadata)
			end
		end
	end
end
