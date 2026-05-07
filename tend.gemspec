require_relative "lib/tend/version"

Gem::Specification.new do |spec|
  spec.name          = "tend"
  spec.version       = Tend::VERSION
  spec.authors       = ["Justin Paulson"]
  spec.email         = ["justinapaulson@gmail.com"]

  spec.summary       = "Ruby SDK for Tend error capture"
  spec.description   = "First-party Ruby gem that captures Rails/Rack backend exceptions and posts them to the Tend webhook ingest endpoint."
  spec.homepage      = "https://github.com/justinpaulson/tend-ruby"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt", "CHANGELOG.md"].select { |f| File.file?(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rack", ">= 2.0"
  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "webmock", "~> 3.20"
  spec.add_development_dependency "rake", "~> 13.0"
end
