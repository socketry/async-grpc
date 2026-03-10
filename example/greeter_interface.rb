# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

require "protocol/grpc/interface"
require_relative "my_service_pb"

# Protocol::GRPC::Interface definition matching my_service.proto.
# Defines all 4 gRPC call types for the Greeter service.
class GreeterInterface < Protocol::GRPC::Interface
	rpc :SayHello, MyService::HelloRequest, MyService::HelloReply
	rpc :StreamNumbers, MyService::HelloRequest, stream(MyService::HelloReply)
	rpc :CollectNames, stream(MyService::HelloRequest), MyService::HelloReply
	rpc :Chat, stream(MyService::HelloRequest), stream(MyService::HelloReply)
end
