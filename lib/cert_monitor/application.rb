# frozen_string_literal: true

module CertMonitor
  # Main application class that handles initialization and startup
  class Application
    # Constants for configuration and timing
    DEFAULT_LOG_LEVEL = 'info'
    MIN_ERROR_SLEEP_DURATION = 10
    HOST_BIND_ADDRESS = '0.0.0.0'
    PROTOCOL_TCP = 'tcp'

    attr_reader :logger, :nacos_client, :checker

    def initialize
      @logger = Logger.create('System')
      @logger.level = ::Logger::INFO # Initial INFO level, updated from config later
      @logger.debug 'Application instance created'
      @previous_check_results = nil
    end

    def start
      @logger.info 'Starting cert-monitor application...'
      @logger.debug 'Beginning application startup sequence'

      startup_sequence
    rescue StandardError => e
      handle_startup_error(e)
    end

    private

    def startup_sequence
      setup_configuration
      setup_logger
      setup_components
      setup_pid_file
      setup_nacos_callback
      start_nacos_client
      perform_initial_checks
      start_checker_thread
      start_exporter
    end

    def handle_startup_error(error)
      @logger.error "Startup failed: #{error.message}"
      @logger.error "Startup error details: #{error.class} - #{error.message}"
      @logger.error "Startup error backtrace: #{error.backtrace.join("\n")}"
      exit 1
    end

    def setup_configuration
      @logger.debug 'Loading configuration...'
      start_time = Time.now

      Config.load

      log_configuration_load_time(start_time)
      log_configuration_source
    end

    def log_configuration_load_time(start_time)
      duration = (Time.now - start_time).round(3)
      @logger.debug "Configuration loaded in #{duration}s"
    end

    def log_configuration_source
      @logger.debug "Nacos enabled: #{Config.nacos_enabled?}"
      source = Config.nacos_enabled? ? 'Nacos' : 'Local file'
      @logger.debug "Configuration source: #{source}"
    end

    def setup_logger
      @logger.debug 'Setting up logger...'

      log_level = determine_log_level
      update_logger_level(log_level)
      log_current_configuration
      @logger.debug "Logger setup completed with level: #{log_level}"
    end

    def determine_log_level
      (Config.log_level || DEFAULT_LOG_LEVEL).upcase
    end

    def update_logger_level(log_level)
      @logger.debug "Setting log level to: #{log_level}"
      Logger.update_all_level(::Logger.const_get(log_level))
    end

    def log_current_configuration
      @logger.info 'Current configuration:'
      log_configuration_items
    end

    def log_configuration_items
      config_items = [
        ['Domains', Config.domains.join(', ')],
        ['Check interval', "#{Config.check_interval}s"],
        ['Connect timeout', "#{Config.connect_timeout}s"],
        ['Expire threshold days', Config.threshold_days.to_s],
        ['Max concurrent checks', Config.max_concurrent_checks.to_s],
        ['Metrics port', Config.metrics_port.to_s],
        ['Log level', Config.log_level.to_s]
      ]

      config_items.each do |key, value|
        @logger.info "- #{key}: #{value}"
      end
    end

    def setup_components
      @logger.debug 'Initializing components...'
      start_time = Time.now

      @checker = Checker.new

      log_component_initialization_time(start_time)
    end

    def log_component_initialization_time(start_time)
      duration = (Time.now - start_time).round(3)
      @logger.debug "Components initialized in #{duration}s"
      @logger.debug 'Checker coordinator ready'
    end

    def setup_nacos_callback
      return unless Config.nacos_enabled?

      @logger.debug 'Setting up Nacos configuration change callback...'
      @config_change_callback = create_config_change_callback
      @logger.debug 'Nacos callback configured'
    end

    def create_config_change_callback
      proc do
        @logger.info 'Configuration changed! Triggering immediate certificate checks...'
        @logger.debug 'Nacos configuration change callback triggered'
        perform_immediate_checks
      end
    end

    def start_nacos_client
      if Config.nacos_enabled?
        start_nacos_client_with_config
      else
        log_nacos_disabled
      end
    end

    def start_nacos_client_with_config
      @logger.info 'Starting Nacos config listener...'
      log_nacos_configuration
      initialize_nacos_client
    end

    def log_nacos_configuration
      @logger.debug "Nacos server: #{Config.nacos_addr}"
      @logger.debug "Nacos namespace: #{Config.nacos_namespace}"
      @logger.debug "Nacos group: #{Config.nacos_group}"
      @logger.debug "Nacos data ID: #{Config.nacos_data_id}"
    end

    def initialize_nacos_client
      @nacos_client = NacosClient.new
      @nacos_client.on_config_change_callback = @config_change_callback
      @nacos_client.start_listening
      @logger.debug 'Nacos client started and listening for configuration changes'
    end

    def log_nacos_disabled
      @logger.info 'Nacos not configured, skipping Nacos client startup'
      @logger.debug 'Using local configuration mode'
    end

    def perform_initial_checks
      @logger.info 'Performing initial certificate checks...'
      @logger.debug 'Starting initial comprehensive certificate check'
      perform_comprehensive_check
    end

    def perform_immediate_checks
      @logger.info 'Executing immediate certificate checks due to configuration change...'
      @logger.debug 'Configuration change triggered immediate check'

      execute_async_check
    end

    def execute_async_check
      Thread.new do
        @logger.debug 'Starting immediate check thread'
        perform_comprehensive_check
        @logger.info 'Immediate certificate checks completed'
        @logger.debug 'Immediate check thread finished'
      rescue StandardError => e
        handle_immediate_check_error(e)
      end
    end

    def handle_immediate_check_error(error)
      @logger.error "Immediate certificate check failed: #{error.message}"
      @logger.debug "Immediate check error details: #{error.class} - #{error.message}"
      @logger.error error.backtrace.join("\n")
    end

    def perform_comprehensive_check
      @logger.debug 'Creating comprehensive check promise'
      start_time = Time.now

      create_check_promise(start_time)
    end

    def create_check_promise(start_time)
      Concurrent::Promise.execute do
        @logger.debug 'Comprehensive check promise started'
        @checker.check_all_certificates
      end.on_success do |results|
        handle_check_success(results, start_time)
      end.on_error do |error|
        handle_check_error(error, start_time)
      end
    end

    def handle_check_success(results, start_time)
      duration = (Time.now - start_time).round(2)
      summary = results[:summary]

      log_check_success(summary, duration)
      log_check_details(summary, results)

      # Check for domain/certificate reduction and restart Puma if needed
      check_and_restart_if_needed(results)

      # Store current results for next comparison
      @previous_check_results = results
    end

    def log_check_success(summary, duration)
      @logger.info 'Comprehensive certificate check completed:'
      @logger.info "- Remote certificates: #{summary[:successful_remote]}/#{summary[:total_remote]} successful"
      @logger.info "- Local certificates: #{summary[:successful_local]}/#{summary[:total_local]} successful"
      @logger.debug "Comprehensive check completed in #{duration}s"
    end

    def log_check_details(summary, results)
      @logger.debug "Check timestamp: #{summary[:check_timestamp]}"
      @logger.debug "Check duration from summary: #{summary[:check_duration]}s"
      @logger.debug "Check had errors: #{results[:error][:message]}" if results[:error]
    end

    def check_and_restart_if_needed(results)
      require_relative 'utils'

      return unless @previous_check_results

      # Check domain reduction
      current_domains = extract_domains_from_results(results)
      previous_domains = extract_domains_from_results(@previous_check_results)

      if current_domains.length < previous_domains.length
        @logger.info "Domain reduction detected. Current: #{current_domains.length}, Previous: #{previous_domains.length}"
        @logger.info "Reduced domains: #{previous_domains - current_domains}"
        @logger.info 'Puma restart triggered due to domain reduction' if Utils.restart_puma
        return
      end

      # Check certificate reduction
      current_total = count_total_certificates(results)
      previous_total = count_total_certificates(@previous_check_results)

      if current_total < previous_total
        @logger.info "Certificate reduction detected. Current: #{current_total}, Previous: #{previous_total}"
        @logger.info 'Puma restart triggered due to certificate reduction' if Utils.restart_puma
      end
    rescue StandardError => e
      @logger.error "Failed to check for restart conditions: #{e.message}"
      @logger.debug "Restart check error details: #{e.class} - #{e.message}"
    end

    # Extract domain list from certificate check results
    def extract_domains_from_results(results)
      domains = []

      # Extract from remote results
      if results[:remote].is_a?(Array)
        results[:remote].each do |result|
          domains << result[:domain] if result[:domain]
        end
      end

      # Extract from local results
      if results[:local].is_a?(Array)
        results[:local].each do |result|
          domains << result[:domain] if result[:domain]
        end
      end

      domains.uniq
    end

    # Calculate total number of certificates from results
    def count_total_certificates(results)
      total = 0

      # Count remote certificates
      total += results[:remote].length if results[:remote].is_a?(Array)

      # Count local certificates
      total += results[:local].length if results[:local].is_a?(Array)

      total
    end

    def handle_check_error(error, start_time)
      duration = (Time.now - start_time).round(2)
      @logger.error "Comprehensive certificate check failed: #{error.message}"
      @logger.debug "Comprehensive check failed after #{duration}s"
      @logger.debug "Check error details: #{error.class} - #{error.message}"
      @logger.error error.backtrace.join("\n")
    end

    def start_checker_thread
      @logger.info 'Starting certificate checker thread...'
      @logger.debug "Check interval: #{Config.check_interval}s"

      create_checker_thread
      @logger.debug 'Checker thread creation completed'
    end

    def create_checker_thread
      Thread.new do
        @logger.debug 'Checker thread started'
        wait_for_first_check
        run_checker_loop
      end
    end

    def wait_for_first_check
      @logger.debug "Waiting #{Config.check_interval}s before first scheduled check"
      sleep Config.check_interval
    end

    def run_checker_loop
      loop do
        @logger.info 'Running scheduled certificate checks...'
        @logger.debug 'Scheduled check triggered'

        perform_comprehensive_check
        wait_for_next_check
      rescue StandardError => e
        handle_checker_thread_error(e)
      end
    end

    def wait_for_next_check
      @logger.debug "Scheduled check initiated, waiting #{Config.check_interval}s for next check"
      sleep Config.check_interval
    end

    def handle_checker_thread_error(error)
      @logger.error "Checker thread error: #{error.message}"
      @logger.debug "Checker thread error details: #{error.class} - #{error.message}"
      @logger.error error.backtrace.join("\n")

      sleep_duration = [Config.check_interval, MIN_ERROR_SLEEP_DURATION].max
      @logger.debug "Sleeping #{sleep_duration}s after error before retry"
      sleep sleep_duration
    end

    def start_exporter
      @logger.debug 'Starting metrics exporter...'
      @logger.debug "Metrics port: #{Config.metrics_port}"
      @logger.debug 'Binding to 0.0.0.0 (IPv4 only) for external access'

      configure_exporter_settings
      start_exporter_server
    end

    def configure_exporter_settings
      Exporter.set :port, Config.metrics_port
      Exporter.set :bind, HOST_BIND_ADDRESS
      Exporter.set :server_settings, create_server_settings
    end

    def create_server_settings
      {
        Host: HOST_BIND_ADDRESS,
        Port: Config.metrics_port,
        binds: ["#{PROTOCOL_TCP}://#{HOST_BIND_ADDRESS}:#{Config.metrics_port}"]
      }
    end

    def start_exporter_server
      @logger.info "Starting metrics server on http://#{HOST_BIND_ADDRESS}:#{Config.metrics_port}"
      Exporter.run! host: HOST_BIND_ADDRESS, port: Config.metrics_port
    end

    def setup_pid_file
      require_relative 'utils'
      if Utils.write_pid_file
        @logger.debug 'PID file written successfully'
      else
        @logger.warn 'Failed to write PID file - Puma restart functionality may not work'
      end
    rescue StandardError => e
      @logger.error "Failed to setup PID file: #{e.message}"
    end
  end
end
