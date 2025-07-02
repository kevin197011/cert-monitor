# frozen_string_literal: true

require 'dotenv'
require 'yaml'
require 'logger'

module CertMonitor
  # Configuration management class for cert-monitor
  # Handles loading and validating configuration from Nacos
  class Config
    class << self
      attr_accessor :nacos_addr, :nacos_namespace, :nacos_group, :nacos_data_id,
                    :domains, :threshold_days, :metrics_port, :log_level,
                    :check_interval, :connect_timeout, :expire_warning_days,
                    :nacos_poll_interval, :max_concurrent_checks

      def load
        # Set default values
        set_defaults

        # Load .env file for Nacos connection info only
        Dotenv.load

        # Load essential Nacos connection info from environment
        load_nacos_connection_config

        validate_nacos_config
      end

      def update_app_config(config_data)
        return false unless config_data.is_a?(Hash)

        # Update domains configuration
        @domains = Array(config_data['domains'] || [])

        # Update settings configuration
        settings = config_data['settings'] || {}

        # Update application configuration from settings
        @metrics_port = (settings['metrics_port'] || @metrics_port).to_i
        @log_level = (settings['log_level'] || @log_level).to_s.downcase
        @check_interval = (settings['check_interval'] || @check_interval).to_i
        @connect_timeout = (settings['connect_timeout'] || @connect_timeout).to_i
        @expire_warning_days = (settings['expire_warning_days'] || @expire_warning_days).to_i
        @nacos_poll_interval = (settings['nacos_poll_interval'] || @nacos_poll_interval).to_i
        @max_concurrent_checks = (settings['max_concurrent_checks'] || @max_concurrent_checks).to_i
        @threshold_days = settings['threshold_days'] || @expire_warning_days

        # Validate configuration
        validate_app_config

        true
      rescue StandardError => e
        logger.error "Configuration update error: #{e.message}"
        false
      end

      private

      def set_defaults
        @log_level = 'info'
        @metrics_port = 9393
        @check_interval = 60 # Default to 60 seconds for SSL check interval
        @connect_timeout = 10
        @expire_warning_days = 30
        @domains = []
        @threshold_days = @expire_warning_days
        @nacos_poll_interval = 30 # Default to 30 seconds for Nacos polling
        @max_concurrent_checks = 50 # Default to 50 concurrent checks
      end

      def load_nacos_connection_config
        # Only load Nacos connection info from environment
        @nacos_addr = ENV['NACOS_ADDR']
        @nacos_namespace = ENV['NACOS_NAMESPACE']
        @nacos_group = ENV['NACOS_GROUP']
        @nacos_data_id = ENV['NACOS_DATA_ID']
      end

      def validate_nacos_config
        raise 'NACOS_ADDR is required' if @nacos_addr.nil? || @nacos_addr.empty?
        raise 'NACOS_NAMESPACE is required' if @nacos_namespace.nil? || @nacos_namespace.empty?
        raise 'NACOS_GROUP is required' if @nacos_group.nil? || @nacos_group.empty?
        raise 'NACOS_DATA_ID is required' if @nacos_data_id.nil? || @nacos_data_id.empty?
      end

      def validate_app_config
        # Validate log level
        @log_level = 'info' unless %w[debug info warn error fatal].include?(@log_level)

        # Validate domain list
        raise 'Domain list cannot be empty' if @domains.empty?
        raise 'Domain list must be an array' unless @domains.is_a?(Array)

        # Validate each domain format
        @domains.each do |domain|
          raise "Invalid domain format: #{domain}" unless domain.is_a?(String) && !domain.empty?
        end

        # Validate numeric values
        raise 'Metrics port must be between 1 and 65535' unless (1..65_535).include?(@metrics_port)
        raise 'Check interval must be positive' unless @check_interval.positive?
        raise 'Connect timeout must be positive' unless @connect_timeout.positive?
        raise 'Expire warning days must be positive' unless @expire_warning_days.positive?
        raise 'Nacos poll interval must be positive' unless @nacos_poll_interval.positive?
        raise 'Max concurrent checks must be positive' unless @max_concurrent_checks.positive?
        raise 'Threshold days must be positive' unless @threshold_days.positive?
      end

      def logger
        @logger ||= Logger.new($stdout)
      end
    end
  end
end
