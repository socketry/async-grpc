# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Alex Watt.

require "async/grpc/error"

describe Async::GRPC::Error do
	it "is a standard error" do
		expect(subject).to be < StandardError
	end
end

describe Async::GRPC::DeadlineExceededError do
	it "is an async gRPC error" do
		expect(subject).to be < Async::GRPC::Error
	end
end

describe Async::GRPC::RemoteError do
	it "is an async gRPC error" do
		expect(subject).to be < Async::GRPC::Error
	end
end
