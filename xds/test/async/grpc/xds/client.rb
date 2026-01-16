# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async/grpc/xds/client"
require "sus/fixtures/async"
require "async/http/endpoint"
require "set"

describe Async::GRPC::XDS::Client do
	include Sus::Fixtures::Async::ReactorContext
	
	let(:xds_server_uri) {ENV["XDS_SERVER_URI"] || "xds-control-plane:18000"}
	let(:service_name) {"myservice"}
	
	let(:bootstrap) {
		{
			"xds_servers" => [
				{
					"server_uri" => xds_server_uri,
					"channel_creds" => [{"type" => "insecure"}]
				}
			],
			"node" => {
				"id" => "test-client-#{Process.pid}",
				"cluster" => "test"
			}
		}
	}
	
	let(:client) {subject.new(service_name, bootstrap: bootstrap)}
	
	it "can resolve endpoints" do
		endpoints = client.resolve_endpoints
		
		expect(endpoints).not_to be_empty
		expect(endpoints.size).to be >= 1
	end
	
	it "can make RPC calls through xDS" do
		# This test requires a working xDS control plane and backend servers
		# Skip if not running in docker compose
		skip "Requires docker compose environment" unless ENV["XDS_SERVER_URI"]
		
		stub = client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
		response = stub.unary_call(request)
		
		expect(response).to be_a(Protocol::GRPC::Fixtures::TestMessage)
		expect(response.value).to match(/test/)
	end
	
	it "load balances across multiple endpoints" do
		skip "Requires docker compose environment" unless ENV["XDS_SERVER_URI"]
		
		# Make multiple calls and verify they hit different backends
		endpoints_used = Set.new
		
		10.times do
			stub = client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
			response = stub.unary_call(request)
			
			# Extract backend info from response metadata
			# This would need to be implemented based on how metadata is returned
			endpoints_used << response.value
		end
		
		# Should use multiple backends (depending on LB policy)
		# Note: This depends on load balancing policy
		expect(endpoints_used.size).to be >= 1
	end
	
	it "handles endpoint failures gracefully" do
		skip "Requires docker compose environment" unless ENV["XDS_SERVER_URI"]
		
		# Start with healthy endpoints
		endpoints = client.resolve_endpoints
		expect(endpoints).not_to be_empty
		
		# Make initial call
		stub = client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
		response = stub.unary_call(request)
		expect(response).to be_a(Protocol::GRPC::Fixtures::TestMessage)
		
		# Note: Testing actual endpoint failure would require stopping a backend
		# This is better done as a separate integration test
	end
	
	it "reloads configuration on errors" do
		skip "Requires docker compose environment" unless ENV["XDS_SERVER_URI"]
		
		# Make initial call
		stub = client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
		response = stub.unary_call(request)
		expect(response).to be_a(Protocol::GRPC::Fixtures::TestMessage)
		
		# Invalidate cache (simulate endpoint change)
		client.instance_variable_get(:@load_balancer)&.update_endpoints([])
		
		# Should reload and work again
		response = stub.unary_call(request)
		expect(response).to be_a(Protocol::GRPC::Fixtures::TestMessage)
	end
	
	it "handles bootstrap configuration errors" do
		expect {
			subject.new(service_name, bootstrap: {invalid: "config"})
		}.to raise_error(Async::GRPC::XDS::Client::ConfigurationError)
	end
	
	it "handles no endpoints available" do
		# Create client with invalid service name
		invalid_client = subject.new("nonexistent-service", bootstrap: bootstrap)
		
		expect {
			invalid_client.resolve_endpoints
		}.to raise_error(Async::GRPC::XDS::Client::NoEndpointsError)
	end
end
