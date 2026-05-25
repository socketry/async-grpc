# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "grpc"
require "my_service_pb"

module MyService
	module Greeter
		# The greeting service definition with all 4 gRPC call types.
		class Service
			include ::GRPC::GenericService
			
			self.marshal_class_method = :encode
			self.unmarshal_class_method = :decode
			self.service_name = "my_service.Greeter"
			
			# Unary: single request, single response
			rpc :SayHello, ::MyService::HelloRequest, ::MyService::HelloReply
			# Server streaming: single request, stream of responses
			rpc :StreamNumbers, ::MyService::HelloRequest, stream(::MyService::HelloReply)
			# Client streaming: stream of requests, single response
			rpc :CollectNames, stream(::MyService::HelloRequest), ::MyService::HelloReply
			# Bidirectional streaming: stream of requests, stream of responses
			rpc :Chat, stream(::MyService::HelloRequest), stream(::MyService::HelloReply)
		end
		
		Stub = Service.rpc_stub_class
	end
end
