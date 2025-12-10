# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025, by Samuel Williams.

require "covered/sus"
include Covered::Sus

# Add fixtures directory to load path
config_dir = ::File.dirname(__FILE__)
project_root = ::File.dirname(config_dir)
fixtures_path = ::File.join(project_root, "fixtures")
$LOAD_PATH.unshift(fixtures_path) unless $LOAD_PATH.include?(fixtures_path)

# Add protocol-grpc fixtures to load path
protocol_grpc_path = ::File.join(project_root, "..", "protocol-grpc")
protocol_grpc_fixtures = ::File.join(protocol_grpc_path, "fixtures")
if ::File.directory?(protocol_grpc_fixtures) && !$LOAD_PATH.include?(protocol_grpc_fixtures)
	$LOAD_PATH.unshift(protocol_grpc_fixtures)
end
