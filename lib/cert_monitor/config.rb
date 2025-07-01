# frozen_string_literal: true

require 'dotenv'
require 'yaml'
require 'logger'

module CertMonitor
  # Configuration management class for cert-monitor
  # Handles loading and validating configuration from environment variables and Nacos
  class Config
    class << self
      attr_accessor :nacos_addr, :nacos_namespace, :nacos_group, :nacos_data_id,
                    :domains, :threshold_days, :port, :log_level,
                    :check_interval, :connect_timeout, :expire_warning_days,
                    :nacos_poll_interval, :max_concurrent_checks

      def load
        # Set default values
        set_defaults

        # Load .env file
        Dotenv.load

        # Load configuration from environment variables
        load_from_env

        validate_config
      end

      def update_domains_config(config_data)
        return false unless config_data.is_a?(Hash)

        # Extract domain list and threshold from YAML configuration
        @domains = Array(config_data['domains'] || [])
        @threshold_days = config_data['threshold_days'] || @expire_warning_days

        # Validate configuration
        validate_domains_config

        true
      rescue StandardError => e
        logger.error "Configuration update error: #{e.message}"
        false
      end

      private

      def set_defaults
        @log_level = 'info'
        @port = 9393
        @check_interval = 60 # Default to 60 seconds for SSL check interval
        @connect_timeout = 10
        @expire_warning_days = 30
        @domains = []
        @threshold_days = @expire_warning_days
        @nacos_poll_interval = 30 # Default to 30 seconds for Nacos polling
        @max_concurrent_checks = 50 # Default to 50 concurrent checks
      end

      def load_from_env
        # Nacos configuration
        @nacos_addr = ENV['NACOS_ADDR']
        @nacos_namespace = ENV['NACOS_NAMESPACE']
        @nacos_group = ENV['NACOS_GROUP']
        @nacos_data_id = ENV['NACOS_DATA_ID']

        # Application configuration
        @port = (ENV['PORT'] || @port).to_i
        @log_level = (ENV['LOG_LEVEL'] || @log_level).to_s.downcase

        # Check configuration
        @check_interval = (ENV['CHECK_INTERVAL'] || @check_interval).to_i
        @connect_timeout = (ENV['CONNECT_TIMEOUT'] || @connect_timeout).to_i
        @expire_warning_days = (ENV['EXPIRE_WARNING_DAYS'] || @expire_warning_days).to_i
        @nacos_poll_interval = (ENV['NACOS_POLL_INTERVAL'] || @nacos_poll_interval).to_i
        @max_concurrent_checks = (ENV['MAX_CONCURRENT_CHECKS'] || @max_concurrent_checks).to_i
      end

      def validate_config
        raise 'NACOS_ADDR is required' if @nacos_addr.nil? || @nacos_addr.empty?
        raise 'NACOS_NAMESPACE is required' if @nacos_namespace.nil? || @nacos_namespace.empty?
        raise 'NACOS_GROUP is required' if @nacos_group.nil? || @nacos_group.empty?
        raise 'NACOS_DATA_ID is required' if @nacos_data_id.nil? || @nacos_data_id.empty?

        # Validate log level
        return if %w[debug info warn error fatal].include?(@log_level)

        @log_level = 'info'
      end

      def validate_domains_config
        # Validate domain list
        raise 'Domain list cannot be empty' if @domains.empty?
        raise 'Domain list must be an array' unless @domains.is_a?(Array)

        # Validate each domain format
        @domains.each do |domain|
          raise "Invalid domain format: #{domain}" unless domain.is_a?(String) && !domain.empty?
        end

        # Validate threshold
        raise 'Threshold days must be greater than 0' unless @threshold_days.to_i.positive?
      end

      def logger
        @logger ||= Logger.new($stdout)
      end
    end
  end
end
