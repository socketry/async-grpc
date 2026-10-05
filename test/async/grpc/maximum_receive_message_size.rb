# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Ateş Göral.

require "async/grpc"
require "async/grpc/test_interface"
require "protocol/http/body/writable"
require "sus/fixtures/async/http"
require "zlib"

AReceiveLimit = Sus::Shared("a receive limit") do
	let(:response_message) {Protocol::GRPC::Fixtures::TestMessage.new(value: "a" * 1024)}
	let(:response_data) {response_message.to_proto}
	let(:response_encoding) {nil}
	let(:response_status) {Protocol::GRPC::Status::OK}
	let(:status_in_trailer) {false}
	let(:interface) {Async::GRPC::Fixtures::TestInterface.new("test.Service")}
	let(:request) {Protocol::GRPC::Fixtures::TestMessage.new(value: "request" * 1024)}
	let(:app) do
		Protocol::HTTP::Middleware.for do |request|
			# Read one request message without waiting for a bidirectional stream to close:
			Protocol::GRPC::Body::Readable.new(request.body).read
			request.body.finish unless request.path.end_with?("/BidirectionalCall")
			headers = Protocol::HTTP::Headers.new([], nil, policy: Protocol::GRPC::HEADER_POLICY)
			headers["content-type"] = "application/grpc"
			headers["grpc-encoding"] = response_encoding if response_encoding
			if status_in_trailer
				headers["trailer"] = "grpc-status"
				headers.trailer!
			end
			Protocol::GRPC::Metadata.assign_status!(headers, status: response_status)
			prefix = [response_encoding ? 1 : 0, response_data.bytesize].pack("CN")
			body = Protocol::HTTP::Body::Writable.new
			body.write(prefix + response_data)
			body.close_write
			Protocol::HTTP::Response[200, headers, body]
		end
	end
	
	def invoke(grpc_client, method)
		case interface.class.lookup_rpc(method).streaming
		when :unary
			grpc_client.invoke(interface, method, request)
		when :server_streaming
			value = nil
			grpc_client.invoke(interface, method, request){|message| value = message}
			value
		when :client_streaming
			grpc_client.invoke(interface, method){|output| output.write(request)}
		when :bidirectional
			value = nil
			grpc_client.invoke(interface, method, initial: [request]) do |output, input|
				output.close_write
				value = input.read
			end
			value
		end
	end
	
	[:UnaryCall, :ServerStreamingCall, :ClientStreamingCall, :BidirectionalCall].each do |method|
		with method.to_s do
			it "accepts exactly the maximum response size without limiting requests" do
				grpc_client = Async::GRPC::Client.new(client, maximum_receive_message_size: response_data.bytesize)
				
				expect(invoke(grpc_client, method)).to be == response_message
			end
			
			it "rejects an oversized response" do
				grpc_client = Async::GRPC::Client.new(client, maximum_receive_message_size: response_data.bytesize - 1)
				
				expect{invoke(grpc_client, method)}.to raise_exception(Protocol::GRPC::Error) do |error|
					expect(error.status_code).to be == Protocol::GRPC::Status::RESOURCE_EXHAUSTED
				end
			end
		end
	end
	
	[:ServerStreamingCall, :BidirectionalCall].each do |method|
		it "enforces the limit on the returned #{method} stream without a block" do
			grpc_client = Async::GRPC::Client.new(client, maximum_receive_message_size: response_data.bytesize - 1)
			input = grpc_client.invoke(interface, method, request, initial: [request])
			
			expect{input.read}.to raise_exception(Protocol::GRPC::Error) do |error|
				expect(error.status_code).to be == Protocol::GRPC::Status::RESOURCE_EXHAUSTED
			end
		ensure
			input&.close
		end
	end
	
	it "leaves responses unlimited by default" do
		grpc_client = Async::GRPC::Client.new(client)
		
		expect(grpc_client.maximum_receive_message_size).to be_nil
		expect(invoke(grpc_client, :UnaryCall)).to be == response_message
	end
	
	with "a non-OK final status" do
		let(:response_status) {Protocol::GRPC::Status::NOT_FOUND}
		let(:status_in_trailer) {true}
		
		it "preserves status validation for an in-limit response" do
			grpc_client = Async::GRPC::Client.new(client, maximum_receive_message_size: response_data.bytesize)
			
			expect{invoke(grpc_client, :UnaryCall)}.to raise_exception(Protocol::GRPC::Error) do |error|
				expect(error.status_code).to be == Protocol::GRPC::Status::NOT_FOUND
			end
		end
	end
	
	{"gzip" => Zlib.method(:gzip), "deflate" => Zlib::Deflate.method(:deflate)}.each do |encoding, compress|
		with encoding do
			let(:response_encoding) {encoding}
			let(:response_message) {Protocol::GRPC::Fixtures::TestMessage.new(value: "a" * 800_000)}
			let(:response_data) {compress.call(response_message.to_proto)}
			
			it "rejects decompression expansion below the wire-size limit" do
				expect(response_data.bytesize).to be < 1024
				grpc_client = Async::GRPC::Client.new(client, maximum_receive_message_size: 1024)
				
				expect{invoke(grpc_client, :UnaryCall)}.to raise_exception(Protocol::GRPC::Error) do |error|
					expect(error.status_code).to be == Protocol::GRPC::Status::RESOURCE_EXHAUSTED
				end
			end
		end
	end
end

describe Async::GRPC::Client do
	with "maximum receive message size" do
		[-1, 1.5, "1024", false].each do |maximum_size|
			it "rejects an invalid maximum size #{maximum_size.inspect}" do
				expect do
					subject.new(Protocol::HTTP::Middleware::Okay, maximum_receive_message_size: maximum_size)
				end.to raise_exception(ArgumentError)
			end
		end
		
		it "passes the limit through .open" do
			client = subject.open("http://localhost:0", maximum_receive_message_size: 1024)
			
			expect(client.maximum_receive_message_size).to be == 1024
		ensure
			client&.close
		end
		
		it "inherits the limit through .with" do
			parent = subject.new(Protocol::HTTP::Middleware::Okay, maximum_receive_message_size: 1024)
			client = subject.with(parent, headers: {"request-id" => "1234"})
			
			expect(client.maximum_receive_message_size).to be == 1024
		end
		
		it "can override or disable an inherited limit" do
			parent = subject.new(Protocol::HTTP::Middleware::Okay, maximum_receive_message_size: 1024)
			
			expect(subject.with(parent, maximum_receive_message_size: 2048).maximum_receive_message_size).to be == 2048
			expect(subject.with(parent, maximum_receive_message_size: nil).maximum_receive_message_size).to be_nil
		end
	end
	
	include Sus::Fixtures::Async::HTTP::ServerContext
	
	with "http/1" do
		let(:protocol) {Async::HTTP::Protocol::HTTP1}
		it_behaves_like AReceiveLimit
	end
	
	with "http/2" do
		let(:protocol) {Async::HTTP::Protocol::HTTP2}
		it_behaves_like AReceiveLimit
	end
end
