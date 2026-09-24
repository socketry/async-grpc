# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "async/grpc/client"
require "protocol/http2/error"

describe Async::GRPC::Client do
	let(:request) {Protocol::HTTP::Request["POST", "/example.Service/Call", {}, nil]}
	
	def client_for(response)
		delegate = Object.new
		delegate.define_singleton_method(:call){|request| response}
		subject.new(delegate)
	end
	
	with "HTTP response validation" do
		{400 => 13, 401 => 16, 403 => 7, 404 => 12, 429 => 14, 502 => 14, 503 => 14, 504 => 14, 500 => 2, 200 => 2}.each do |http, grpc|
			it "maps HTTP #{http} without decoding an HTML body" do
				response = Protocol::HTTP::Response[http, {"content-type" => "text/html"}, ["<!DOCTYPE html>"]]
				expect do
					client_for(response).call(request)
				end.to raise_exception(Protocol::GRPC::Error, message: be =~ /Invalid gRPC response/).and(have_attributes(status_code: be == grpc))
				expect(response.body).to be_nil
			end
		end
		
		it "preserves explicit gRPC errors over the HTTP fallback" do
			response = Protocol::HTTP::Response[503, {"grpc-status" => "16", "grpc-message" => "Token%20expired"}, []]
			expect do
				client_for(response).call(request)
			end.to raise_exception(Protocol::GRPC::Unauthenticated)
		end
		
		it "reads trailers without decoding a non-gRPC body" do
			headers = Protocol::HTTP::Headers.new
			body = Protocol::HTTP::Body::Buffered.new(["HTML"])
			body.define_singleton_method(:read) do
				chunk = super()
				headers["grpc-status"] = "16" unless chunk
				chunk
			end
			response = Protocol::HTTP::Response[503, headers, body]
			expect{client_for(response).call(request)}.to raise_exception(Protocol::GRPC::Unauthenticated)
		end
		
		["application/grpc", "application/grpc+proto", "application/grpc+json", "application/grpc; charset=utf-8"].each do |content_type|
			it "accepts #{content_type}" do
				response = Protocol::HTTP::Response[200, {"content-type" => content_type, "grpc-status" => "0"}, nil]
				expect(client_for(response).call(request)).to be_equal(response)
			end
		end
		
		[nil, "application/grpc-web", "text/html"].each do |content_type|
			it "rejects invalid content type #{content_type.inspect}" do
				headers = {"grpc-status" => "0"}
				headers["content-type"] = content_type if content_type
				response = Protocol::HTTP::Response[200, headers, []]
				expect{client_for(response).call(request)}.to raise_exception(Protocol::GRPC::Internal)
			end
		end
	end
	
	with "transport errors" do
		[Errno::ECONNREFUSED.new, Errno::ECONNRESET.new, EOFError.new, SocketError.new, OpenSSL::SSL::SSLError.new, Protocol::HTTP2::GoawayError.new("Disconnected")].each do |failure|
			it "converts #{failure.class} while connecting" do
				delegate = Object.new
				delegate.define_singleton_method(:call){|request| raise failure}
				expect do
					subject.new(delegate).call(request)
				end.to raise_exception(Protocol::GRPC::Unavailable).and(have_attributes(cause: be_equal(failure)))
			end
		end
		
		it "converts connection failures while reading response bytes" do
			failure = Errno::ECONNRESET.new
			body = Protocol::HTTP::Body::Buffered.new(["unread"])
			body.define_singleton_method(:read){raise failure}
			response = Protocol::HTTP::Response[200, {"content-type" => "application/grpc"}, body]
			result = client_for(response).call(request)
			expect{result.body.read}.to raise_exception(Protocol::GRPC::Unavailable).and(have_attributes(cause: be_equal(failure)))
		ensure
			result&.close
		end
		
		it "does not convert caller timeouts into unavailable errors" do
			delegate = Object.new
			delegate.define_singleton_method(:call){|request| raise Async::TimeoutError}
			expect{subject.new(delegate).call(request)}.to raise_exception(Async::TimeoutError)
		end
	end
end
