# frozen_string_literal: true

require_relative 'lib/cert_monitor/version'

Gem::Specification.new do |spec|
  spec.name          = 'cert-monitor'
  spec.version       = CertMonitor::VERSION
  spec.authors       = ['Your Name']
  spec.email         = ['your.email@example.com']

  spec.summary       = 'SSL Certificate Monitoring Tool'
  spec.description   = 'A Ruby-based online domain certificate monitoring tool that supports Nacos configuration center and Prometheus metrics export'
  spec.homepage      = 'https://github.com/yourusername/cert-monitor'
  spec.license       = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>= 2.6.0')

  spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"

  spec.files         = Dir.glob('{bin,lib}/**/*') + %w[README.md]
  spec.bindir        = 'bin'
  spec.executables   = ['cert-monitor']
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'concurrent-ruby', '~> 1.1'
  spec.add_dependency 'dotenv', '~> 2.8'
  spec.add_dependency 'prometheus-client', '~> 4.2'
  spec.add_dependency 'puma', '~> 6.0'
  spec.add_dependency 'rake', '~> 13.0'
  spec.add_dependency 'sinatra', '~> 2.2'

  # Development dependencies
  spec.add_development_dependency 'bundler', '~> 2.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
end
