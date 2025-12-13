# frozen_string_literal: true

require_relative "lib/async/grpc/version"

Gem::Specification.new do |spec|
	spec.name = "async-grpc"
	spec.version = Async::GRPC::VERSION
	
	spec.summary = "Client and server implementation for gRPC using Async."
	spec.authors = ["Samuel Williams"]
	spec.license = "MIT"
	
	spec.homepage = "https://github.com/socketry/async-grpc"
	
	spec.metadata = {
		"documentation_uri" => "https://socketry.github.io/async-grpc/",
		"source_code_uri" => "https://github.com/socketry/async-grpc.git",
	}
	
	spec.files = Dir.glob(["{context,lib}/**/*", "*.md"], File::FNM_DOTMATCH, base: __dir__)
	
	spec.required_ruby_version = ">= 3.2"
	
	spec.add_dependency "async-http"
	spec.add_dependency "protocol-grpc", "~> 0.5"
end
