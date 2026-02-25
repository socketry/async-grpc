# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

# Generate Ruby protobuf classes from Envoy .proto files
# @parameter proto_dir [String] Directory containing .proto files (default: "proto")
# @parameter output_dir [String] Output directory for generated Ruby files (default: "lib")
def generate_protos(proto_dir: "proto", output_dir: "lib")
	require "fileutils"
	
	proto_dir = File.expand_path(proto_dir)
	output_dir = File.expand_path(output_dir)
	
	# Core discovery service files (most important)
	discovery_files = [
		"envoy/service/discovery/v3/discovery.proto",
		"envoy/service/discovery/v3/ads.proto"
	]
	
	# Core config files needed for discovery
	config_files = [
		"envoy/config/core/v3/base.proto",
		"envoy/config/core/v3/address.proto",
		"envoy/config/core/v3/config_source.proto",
		"envoy/config/cluster/v3/cluster.proto",
		"envoy/config/endpoint/v3/endpoint.proto"
	]
	
	# Google protobuf well-known types
	google_files = [
		"google/protobuf/any.proto",
		"google/protobuf/duration.proto",
		"google/protobuf/timestamp.proto",
		"google/protobuf/struct.proto",
		"google/protobuf/empty.proto",
		"google/protobuf/wrappers.proto",
		"google/rpc/status.proto"
	]
	
	all_files = discovery_files + config_files + google_files
	
	# Create output directories
	FileUtils.mkdir_p(output_dir)
	
	# Generate Ruby code
	all_files.each do |proto_file|
		full_path = File.join(proto_dir, proto_file)
		next unless File.exist?(full_path)
		
		Console.info{"Generating #{proto_file}..."}
		
		system(
			"protoc",
			"--ruby_out=#{output_dir}",
			"--proto_path=#{proto_dir}",
			"--proto_path=#{File.join(proto_dir, 'google')}",
			full_path,
			out: File::NULL,
			err: File::NULL
		) or begin
			Console.warn{"Failed to generate #{proto_file} (may have missing dependencies)"}
		end
	end
	
	# Count generated files
	generated = Dir.glob(File.join(output_dir, "**/*_pb.rb")).count
	
	Console.info{"Generated #{generated} protobuf Ruby files in #{output_dir}"}
end

# Generate all protobuf files (including optional dependencies)
# This will attempt to generate all .proto files, even if some fail
# @parameter proto_dir [String] Directory containing .proto files (default: "proto")
# @parameter output_dir [String] Output directory for generated Ruby files (default: "lib")
def generate_all_protos(proto_dir: "proto", output_dir: "lib")
	require "fileutils"
	
	proto_dir = File.expand_path(proto_dir)
	output_dir = File.expand_path(output_dir)
	
	# Find all .proto files
	proto_files = Dir.glob(File.join(proto_dir, "**/*.proto"))
	
	Console.info{"Found #{proto_files.count} .proto files"}
	
	# Generate each file
	success_count = 0
	fail_count = 0
	
	proto_files.each do |proto_file|
		relative_path = proto_file.sub(/^#{proto_dir}\//, "")
		
		Console.debug{"Generating #{relative_path}..."}
		
		if system(
			"protoc",
			"--ruby_out=#{output_dir}",
			"--proto_path=#{proto_dir}",
			"--proto_path=#{File.join(proto_dir, 'google')}",
			proto_file,
			out: File::NULL,
			err: File::NULL
		)
			success_count += 1
		else
			fail_count += 1
			Console.debug{"Failed: #{relative_path}"}
		end
	end
	
	# Count generated files
	generated = Dir.glob(File.join(output_dir, "**/*_pb.rb")).count
	
	Console.info{"Generated #{generated} protobuf Ruby files (#{success_count} succeeded, #{fail_count} failed)"}
end
