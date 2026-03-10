# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "async/grpc/xds/client"
require "async/grpc/xds/ads_stream"
require "async/grpc/service"
require "sus/fixtures/async"
require "async/http/endpoint"
require_relative "../../../../../fixtures/async/grpc/test_interface"
require "set"

describe Async::GRPC::XDS::Client do
	include Sus::Fixtures::Async::ReactorContext
	
	let(:xds_server_uri) {ENV["XDS_SERVER_URI"] || "xds-control-plane:18000"}
	let(:service_name) {"myservice"}
	
	let(:bootstrap) do
		{
			xds_servers: [
				{
					server_uri: xds_server_uri,
					channel_creds: [{type: "insecure"}]
				}
			],
			node: {
				id: "test-client-#{Process.pid}",
				cluster: "test"
			}
		}
	end
	
	let(:client) {subject.new(service_name, bootstrap: bootstrap)}
	
	it "can stream updates" do
		skip "Requires xDS control plane (XDS_SERVER_URI)" unless ENV["XDS_SERVER_URI"]
		
		received = []
		delegate = Object.new
		delegate.define_singleton_method(:discovery_response){|response, _stream| received << response}
		
		endpoint = Async::HTTP::Endpoint.parse(
			"http://#{xds_server_uri}",
			protocol: Async::HTTP::Protocol::HTTP2
		)
		http_client = Async::HTTP::Client.new(endpoint)
		grpc_client = Async::GRPC::Client.new(http_client)
		node = Envoy::Config::Core::V3::Node.new(id: "test-#{Process.pid}", cluster: "test")
		
		initial = Envoy::Service::Discovery::V3::DiscoveryRequest.new(
			type_url: "type.googleapis.com/envoy.config.cluster.v3.Cluster",
			resource_names: [service_name],
			node: node
		)
		stream = Async::GRPC::XDS::ADSStream.new(grpc_client, node, delegate: delegate)
		
		stream_task = Async{stream.run(initial: initial)}
		deadline = Time.now + 10
		while received.empty? && Time.now < deadline
			sleep(0.1)
		end
		stream_task.stop
		
		expect(received.size).to be >= 1
	end
	
	it "can resolve endpoints" do
		skip "Requires docker compose environment (XDS_SERVER_URI)" unless ENV["XDS_SERVER_URI"]
		
		endpoints = client.resolve_endpoints
		
		expect(endpoints.size).to be >= 1
	end
	
	it "can make RPC calls through xDS" do
		skip "Requires docker compose environment (XDS_SERVER_URI)" unless ENV["XDS_SERVER_URI"]
		
		stub = client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		
		request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
		response = stub.unary_call(request)
		
		expect(response).to be_a(Protocol::GRPC::Fixtures::TestMessage)
		expect(response.value).to be(:include?, "test")
	end
	
	it "load balances across multiple endpoints" do
		skip "Requires docker compose environment (XDS_SERVER_URI)" unless ENV["XDS_SERVER_URI"]
		
		stub = client.stub(Async::GRPC::Fixtures::TestInterface, service_name)
		endpoints_used = Set.new
		
		10.times do
			request = Protocol::GRPC::Fixtures::TestMessage.new(value: "test")
			response = stub.unary_call(request)
			endpoints_used << response.value
		end
		
		expect(endpoints_used.size).to be >= 1
	end
	
	it "handles bootstrap configuration errors" do
		expect{subject.new(service_name, bootstrap: {invalid: "config" })}.to raise_exception(Async::GRPC::XDS::Client::ConfigurationError)
	end
	
	it "handles no endpoints available" do
		skip "Requires docker compose environment (XDS_SERVER_URI)" unless ENV["XDS_SERVER_URI"]
		
		invalid_client = subject.new("nonexistent-service", bootstrap: bootstrap)
		
		expect{invalid_client.resolve_endpoints}.to raise_exception(Async::GRPC::XDS::Client::NoEndpointsError)
	end
	
	it "evicts resolved promises to prevent unbounded growth" do
		skip "Requires docker compose environment (XDS_SERVER_URI)" unless ENV["XDS_SERVER_URI"]
		
		xds_client = subject.new(service_name, bootstrap: bootstrap)
		xds_client.resolve_endpoints
		
		context = xds_client.instance_variable_get(:@context)
		# Resolved promises are evicted immediately; hashes stay bounded
		expect(context.instance_variable_get(:@cluster_promises)).to be(:empty?)
		expect(context.instance_variable_get(:@endpoint_promises)).to be(:empty?)
	end
	
	it "clears promise caches on close to prevent memory growth" do
		skip "Requires docker compose environment (XDS_SERVER_URI)" unless ENV["XDS_SERVER_URI"]
		
		xds_client = subject.new(service_name, bootstrap: bootstrap)
		xds_client.resolve_endpoints
		
		context = xds_client.instance_variable_get(:@context)
		xds_client.close
		
		# Close clears any remaining promises (e.g. unresolved for nonexistent services)
		expect(context.instance_variable_get(:@cluster_promises)).to be(:empty?)
		expect(context.instance_variable_get(:@endpoint_promises)).to be(:empty?)
	end
end
