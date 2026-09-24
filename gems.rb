# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2025-2026, by Samuel Williams.

source "https://rubygems.org"

gemspec

# Use the protocol fixes while their release is pending:
gem "protocol-grpc", git: "https://github.com/socketry/protocol-grpc.git", ref: "cb474e449da5864a91206a680c2543e84619ea89"

group :maintenance, optional: true do
	gem "bake-gem"
	gem "bake-modernize"
	gem "bake-releases"
	
	gem "agent-context"
	
	gem "decode"
	
	gem "utopia-project"
end

group :test do
	gem "covered"
	gem "sus"
	
	gem "rubocop"
	gem "rubocop-md"
	gem "rubocop-socketry"
	
	gem "sus-fixtures-async-http"
	
	gem "bake-test"
end
