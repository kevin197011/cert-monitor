# frozen_string_literal: true

module CertMonitor
  # Configuration management class for cert-monitor
  # Handles loading and validating configuration from Nacos or local file
  class Config
    class << self
      attr_accessor :nacos_addr, :nacos_namespace, :nacos_group, :nacos_data_id,
                    :nacos_username, :nacos_password,
                    :domains, :threshold_days, :metrics_port, :log_level,
                    :check_interval, :connect_timeout, :expire_warning_days,
                    :nacos_poll_interval, :max_concurrent_checks

      def load
        logger.debug 'Starting configuration loading process'

        # Set default values
        set_defaults
        logger.debug 'Default values set'

        # Load .env file for Nacos connection info only
        Dotenv.load
        logger.debug 'Environment variables loaded from .env file'

        # Load essential Nacos connection info from environment
        load_nacos_connection_config
        logger.debug 'Nacos connection configuration loaded'

        # Load configuration from Nacos or local file
        if nacos_enabled?
          logger.debug 'Nacos configuration detected'
          # Validate Nacos configuration
          validate_nacos_config
          logger.info 'Nacos configuration enabled, waiting for remote config...'
          logger.debug 'Nacos configuration validation completed'
        else
          logger.debug 'Local configuration mode detected'
          # Load from local configuration file
          load_local_config
          logger.info 'Using local configuration file'
        end

        logger.debug 'Configuration loading process completed'
      end

      def nacos_enabled?
        enabled = !@nacos_addr.nil? && !@nacos_addr.empty?
        logger.debug "Nacos enabled check: #{enabled} (nacos_addr: #{@nacos_addr})"
        enabled
      end

      def update_app_config(config_data)
        logger.debug 'Starting application configuration update'
        logger.debug "Received config data: #{config_data.inspect}"

        return false unless config_data.is_a?(Hash)

        # Update domains configuration
        old_domains = @domains.dup
        @domains = Array(config_data['domains'] || [])
        logger.debug "Domains updated from #{old_domains.inspect} to #{@domains.inspect}"

        # Update settings configuration
        settings = config_data['settings'] || {}
        logger.debug "Settings section: #{settings.inspect}"

        # Update application configuration from settings
        old_values = {
          metrics_port: @metrics_port,
          log_level: @log_level,
          check_interval: @check_interval,
          connect_timeout: @connect_timeout,
          expire_warning_days: @expire_warning_days,
          nacos_poll_interval: @nacos_poll_interval,
          max_concurrent_checks: @max_concurrent_checks
        }

        @metrics_port = (settings['metrics_port'] || @metrics_port).to_i
        @log_level = (settings['log_level'] || @log_level).to_s.downcase
        @check_interval = (settings['check_interval'] || @check_interval).to_i
        @connect_timeout = (settings['connect_timeout'] || @connect_timeout).to_i
        @expire_warning_days = (settings['expire_warning_days'] || @expire_warning_days).to_i
        @nacos_poll_interval = (settings['nacos_poll_interval'] || @nacos_poll_interval).to_i
        @max_concurrent_checks = (settings['max_concurrent_checks'] || @max_concurrent_checks).to_i
        @threshold_days = settings['threshold_days'] || @expire_warning_days

        new_values = {
          metrics_port: @metrics_port,
          log_level: @log_level,
          check_interval: @check_interval,
          connect_timeout: @connect_timeout,
          expire_warning_days: @expire_warning_days,
          nacos_poll_interval: @nacos_poll_interval,
          max_concurrent_checks: @max_concurrent_checks
        }

        # 记录配置变化
        changed_settings = []
        old_values.each do |key, old_value|
          new_value = new_values[key]
          changed_settings << "#{key}: #{old_value} -> #{new_value}" if old_value != new_value
        end

        if changed_settings.any?
          logger.debug "Configuration changes detected: #{changed_settings.join(', ')}"
        else
          logger.debug 'No configuration changes detected'
        end

        # Validate configuration
        logger.debug 'Validating updated configuration'
        validate_app_config
        logger.debug 'Configuration validation completed'

        logger.debug 'Application configuration update completed successfully'
        true
      rescue StandardError => e
        logger.error "Configuration update error: #{e.message}"
        logger.debug "Configuration update error details: #{e.class} - #{e.backtrace.first(3).join(', ')}"
        false
      end

      private

      def set_defaults
        logger.debug 'Setting default configuration values'

        @log_level = 'info'
        @metrics_port = 9393
        @check_interval = 60 # Default to 60 seconds for SSL check interval
        @connect_timeout = 10
        @expire_warning_days = 30
        @domains = []
        @threshold_days = @expire_warning_days
        @nacos_poll_interval = 30 # Default to 30 seconds for Nacos polling
        @max_concurrent_checks = 50 # Default to 50 concurrent checks

        logger.debug "Default values: log_level=#{@log_level}, metrics_port=#{@metrics_port}, check_interval=#{@check_interval}s"
        logger.debug "Default values: connect_timeout=#{@connect_timeout}s, expire_warning_days=#{@expire_warning_days}, max_concurrent_checks=#{@max_concurrent_checks}"
      end

      def load_nacos_connection_config
        logger.debug 'Loading Nacos connection configuration from environment'

        # Load Nacos connection info from environment
        @nacos_addr = ENV['NACOS_ADDR']
        @nacos_namespace = ENV['NACOS_NAMESPACE']
        @nacos_group = ENV['NACOS_GROUP'] || 'DEFAULT_GROUP'
        @nacos_data_id = ENV['NACOS_DATA_ID'] || 'cert-monitor-config'
        @nacos_username = ENV['NACOS_USERNAME']
        @nacos_password = ENV['NACOS_PASSWORD']

        logger.debug "Nacos connection config: addr=#{@nacos_addr}, namespace=#{@nacos_namespace}, group=#{@nacos_group}, data_id=#{@nacos_data_id}"
        logger.debug "Nacos authentication: username=#{@nacos_username ? 'set' : 'not set'}, password=#{@nacos_password ? 'set' : 'not set'}"
      end

      def load_local_config
        config_file = ENV['CONFIG_FILE'] || 'config/domains.yml'
        logger.debug "Loading local configuration from: #{config_file}"

        unless File.exist?(config_file)
          logger.warn "Configuration file #{config_file} not found, using defaults"
          logger.debug "Checked file path: #{File.expand_path(config_file)}"
          return
        end

        file_size = File.size(config_file)
        logger.debug "Configuration file size: #{file_size} bytes"

        begin
          config_data = YAML.load_file(config_file)
          logger.debug "Loaded configuration from #{config_file}: #{config_data.inspect}"

          if config_data.is_a?(Hash)
            logger.debug 'Configuration file format is valid (Hash)'
            update_app_config(config_data)
            logger.info "Configuration loaded successfully from #{config_file}"
          else
            logger.error "Invalid configuration format in #{config_file}"
            logger.debug "Expected Hash, got #{config_data.class}: #{config_data.inspect}"
          end
        rescue StandardError => e
          logger.error "Failed to load configuration from #{config_file}: #{e.message}"
          logger.debug "Local config load error: #{e.class} - #{e.message}"
          logger.debug e.backtrace.join("\n")
        end
      end

      def validate_nacos_config
        logger.debug 'Validating Nacos configuration'

        raise 'NACOS_ADDR is required' if @nacos_addr.nil? || @nacos_addr.empty?
        # nacos_namespace can be empty (for default namespace)
        raise 'NACOS_GROUP is required' if @nacos_group.nil? || @nacos_group.empty?
        raise 'NACOS_DATA_ID is required' if @nacos_data_id.nil? || @nacos_data_id.empty?

        # username and password are optional but should be used together
        if @nacos_username && @nacos_password
          logger.info 'Nacos authentication enabled'
          logger.debug 'Both username and password provided for Nacos authentication'
        elsif @nacos_username || @nacos_password
          logger.warn 'Nacos authentication partially configured (username or password missing)'
        else
          logger.debug 'Nacos authentication not configured'
        end

        logger.debug 'Nacos configuration validation passed'
      end

      def validate_app_config
        logger.debug 'Validating application configuration'

        # Validate log level
        old_log_level = @log_level
        @log_level = 'info' unless %w[debug info warn error fatal].include?(@log_level)
        logger.debug "Log level corrected from '#{old_log_level}' to '#{@log_level}'" if old_log_level != @log_level

        # Allow empty domain list for initial setup
        if @domains.empty?
          logger.warn 'Domain list is empty'
          logger.debug 'No domains configured for monitoring'
          return
        end

        # Validate domain list
        raise 'Domain list must be an array' unless @domains.is_a?(Array)

        logger.debug "Validating #{@domains.length} domains"

        # Validate each domain format
        @domains.each_with_index do |domain, index|
          unless domain.is_a?(String) && !domain.empty?
            logger.error "Invalid domain at index #{index}: #{domain.inspect}"
            raise "Invalid domain format: #{domain}"
          end
          logger.debug "Domain #{index + 1}: #{domain} - valid"
        end

        # Validate numeric values
        validations = [
          { name: 'Metrics port', value: @metrics_port, range: 1..65_535 },
          { name: 'Check interval', value: @check_interval, condition: :positive? },
          { name: 'Connect timeout', value: @connect_timeout, condition: :positive? },
          { name: 'Expire warning days', value: @expire_warning_days, condition: :positive? },
          { name: 'Nacos poll interval', value: @nacos_poll_interval, condition: :positive? },
          { name: 'Max concurrent checks', value: @max_concurrent_checks, condition: :positive? },
          { name: 'Threshold days', value: @threshold_days, condition: :positive? }
        ]

        validations.each do |validation|
          value = validation[:value]
          name = validation[:name]

          if validation[:range]
            unless validation[:range].include?(value)
              logger.error "#{name} validation failed: #{value} not in range #{validation[:range]}"
              raise "#{name} must be between #{validation[:range].first} and #{validation[:range].last}"
            end
          elsif validation[:condition] == :positive?
            unless value.positive?
              logger.error "#{name} validation failed: #{value} is not positive"
              raise "#{name} must be positive"
            end
          end

          logger.debug "#{name} validation passed: #{value}"
        end

        logger.debug 'Application configuration validation completed'
      end

      def logger
        @logger ||= Logger.create('Config')
      end
    end
  end
end
