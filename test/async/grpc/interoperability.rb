# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "async/grpc/client"
require "protocol/http/body/writable"

describe Async::GRPC::Client do
	let(:request) {Protocol::HTTP::Request["POST", "/example.Service/Call", {}, nil]}
	
	def client_for(response)
		delegate = Object.new
		delegate.define_singleton_method(:call){|request| response}
		subject.new(delegate)
	end
	
	with "HTTP response validation" do
		it "preserves the HTTP response and HTML body in the error" do
			response = Protocol::HTTP::Response[503, {"content-type" => "text/html", "x-request-id" => "123"}, ["<html>", "Proxy failure!", "</html>"]]
			expect do
				client_for(response).call(request)
			end.to raise_exception(Async::GRPC::ResponseError, message: be == "Invalid gRPC response: HTTP 503, content-type \"text/html\"!").and(have_attributes(response: be_equal(response)))
			expect(response.headers["x-request-id"]).to be == ["123"]
			expect(response.body).to be_a(Protocol::HTTP::Body::Buffered)
			expect(response.read).to be == "<html>Proxy failure!</html>"
		end
		
		it "rejects a non-200 status even with gRPC content type and OK status" do
			response = Protocol::HTTP::Response[503, {"content-type" => "application/grpc", "grpc-status" => "0"}, nil]
			expect do
				client_for(response).call(request)
			end.to raise_exception(Async::GRPC::ResponseError, message: be =~ /HTTP 503/)
			expect(response.body).to be_nil
		end
		
		it "closes the body when reading an invalid response fails" do
			body = Protocol::HTTP::Body::Writable.new
			body.define_singleton_method(:read){raise RuntimeError, "Read failed!"}
			response = Protocol::HTTP::Response[503, {"content-type" => "text/html"}, body]
			
			expect{client_for(response).call(request)}.to raise_exception(RuntimeError, message: be == "Read failed!")
			expect(body).to be(:closed?)
		end
		
		["application/grpc", "application/grpc+proto", "application/grpc+json", "application/grpc; charset=utf-8"].each do |content_type|
			it "accepts #{content_type}" do
				response = Protocol::HTTP::Response[200, {"content-type" => content_type, "grpc-status" => "0"}, ["unread"]]
				expect(client_for(response).call(request)).to be_equal(response)
				expect(response.body.read).to be == "unread"
			ensure
				response.close
			end
		end
		
		[nil, "application/grpc-web", "text/html"].each do |content_type|
			it "rejects invalid content type #{content_type.inspect}" do
				headers = {"grpc-status" => "0"}
				headers["content-type"] = content_type if content_type
				response = Protocol::HTTP::Response[200, headers, []]
				expect{client_for(response).call(request)}.to raise_exception(Async::GRPC::ResponseError)
			end
		end
	end
end
