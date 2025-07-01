# frozen_string_literal: true

# Main entry point for the cert-monitor gem
# This file loads all required components and sets up the application

require 'cert_monitor/version'
require 'cert_monitor/config'
require 'cert_monitor/nacos_client'
require 'cert_monitor/checker'
require 'cert_monitor/exporter'

module CertMonitor
  class Error < StandardError; end
end
