# frozen_string_literal: true

module CertMonitor
  # Nacos configuration client class
  # Handles communication with Nacos configuration center and configuration updates
  class NacosClient
    attr_accessor :on_config_change_callback

    def initialize
      @config = Config
      @logger = Logger.create('Nacos')
      @last_md5 = nil
      @running = Concurrent::AtomicBoolean.new(false)
      @on_config_change_callback = nil
    end

    # Start listening for configuration changes from Nacos
    # Runs in a separate thread and periodically checks for updates
    def start_listening
      return if @running.true?

      @running.make_true
      log_startup_info
      start_listener_thread
    end

    # Stop listening for configuration changes
    def stop_listening
      @running.make_false
      @logger.info 'Nacos config listener stopped'
    end

    private

    def log_startup_info
      @logger.info 'Starting Nacos config listener...'
      @logger.debug "Configuration details: dataId=#{@config.nacos_data_id}, group=#{@config.nacos_group}, namespace=#{@config.nacos_namespace}"
      @logger.debug "Nacos server: #{@config.nacos_addr}"
      @logger.info "Initial polling interval: #{@config.nacos_poll_interval} seconds"
    end

    def start_listener_thread
      Thread.new do
        run_listener_loop
      rescue StandardError => e
        handle_listener_error(e)
      end
    end

    def run_listener_loop
      while @running.true?
        begin
          check_config_update
          sleep @config.nacos_poll_interval
        rescue StandardError => e
          handle_config_check_error(e)
        end
      end
    end

    def handle_listener_error(error)
      @logger.error "Nacos listener thread error: #{error.message}"
      @logger.debug "Listener error details: #{error.class} - #{error.message}"
      @logger.error error.backtrace.join("\n")
    end

    def handle_config_check_error(error)
      @logger.error "Configuration update error: #{error.message}"
      @logger.debug "Config check error details: #{error.class} - #{error.message}"
      @logger.debug error.backtrace.join("\n")

      # Use max of poll interval or 10 seconds on error
      sleep_duration = [@config.nacos_poll_interval, 10].max
      @logger.debug "Sleeping #{sleep_duration}s after error before retry"
      sleep sleep_duration
    end

    # Check for configuration updates from Nacos
    # Uses MD5 hash to detect changes and updates local configuration if needed
    def check_config_update
      response = fetch_config_from_nacos
      return unless response

      yaml_content = response.body
      return if yaml_content.nil? || yaml_content.strip.empty?

      process_config_content(yaml_content)
    end

    def fetch_config_from_nacos
      uri = build_nacos_uri
      http = create_http_client(uri)

      @logger.debug "Requesting config from: #{uri}"
      response = http.get(uri.request_uri)
      @logger.debug "Response status: #{response.code}"

      if response.is_a?(Net::HTTPSuccess)
        response
      else
        handle_http_error(response)
        nil
      end
    rescue StandardError => e
      handle_http_request_error(e)
      nil
    end

    def build_nacos_uri
      uri = URI.join(@config.nacos_addr, '/nacos/v1/cs/configs')
      uri.query = URI.encode_www_form(config_params)
      uri
    end

    def create_http_client(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 10
      http.open_timeout = 5
      http
    end

    def handle_http_error(response)
      @logger.error "Failed to fetch configuration: HTTP #{response.code} - #{response.body}"
      raise "Failed to fetch configuration: HTTP #{response.code}"
    end

    def handle_http_request_error(error)
      @logger.error "HTTP request failed: #{error.message}"
      @logger.debug "HTTP request error details: #{error.class} - #{error.message}"
      raise error
    end

    def process_config_content(yaml_content)
      @logger.debug "Raw response body length: #{yaml_content.length}"
      @logger.debug "Raw response body content: #{yaml_content}"

      current_md5 = Digest::MD5.hexdigest(yaml_content)
      @logger.info "Content MD5: #{current_md5}, Last MD5: #{@last_md5}"

      if @last_md5 == current_md5
        @logger.info 'Configuration unchanged (same MD5)'
        return
      end

      @last_md5 = current_md5
      update_configuration(yaml_content)
    end

    def update_configuration(yaml_content)
      config_data = parse_yaml_content(yaml_content)
      return unless config_data

      validate_config_format(config_data)
      apply_configuration(config_data)
    rescue Psych::SyntaxError => e
      handle_yaml_parsing_error(e, yaml_content)
    rescue StandardError => e
      handle_config_update_error(e)
    end

    def parse_yaml_content(yaml_content)
      config_data = YAML.safe_load(yaml_content)
      @logger.debug "Parsed YAML config: #{config_data.inspect}"
      @logger.debug "Config data class: #{config_data.class}"
      config_data
    end

    def validate_config_format(config_data)
      return if config_data.is_a?(Hash)

      @logger.error "Invalid configuration format: expected Hash, got #{config_data.class}"
      @logger.debug "Raw config data: #{config_data.inspect}"
      raise 'Invalid configuration format: not a valid YAML configuration'
    end

    def apply_configuration(config_data)
      @logger.debug "Domains in config: #{config_data['domains'].inspect}"
      @logger.debug "Settings in config: #{config_data['settings'].inspect}"

      if @config.update_app_config(config_data)
        log_configuration_update(config_data)
        update_log_level_if_needed(config_data)
        trigger_config_change_callback
      else
        @logger.error 'Failed to update configuration'
      end
    end

    def log_configuration_update(_config_data)
      @logger.info 'Configuration updated successfully'
      @logger.debug "Current configuration: metrics_port=#{@config.metrics_port}, check_interval=#{@config.check_interval}s"
      @logger.debug "Monitored domains: #{@config.domains.inspect}"
    end

    def update_log_level_if_needed(config_data)
      return unless config_data['settings'] && config_data['settings']['log_level']

      new_log_level = config_data['settings']['log_level'].upcase
      Logger.update_all_level(::Logger.const_get(new_log_level))
      @logger.info "Log level updated to: #{new_log_level}"
      @logger.debug "Current metrics port: #{@config.metrics_port}"
    end

    def trigger_config_change_callback
      return unless @on_config_change_callback

      @logger.debug 'Triggering config change callback...'
      begin
        @on_config_change_callback.call
      rescue StandardError => e
        handle_callback_error(e)
      end
    end

    def handle_callback_error(error)
      @logger.error "Config change callback failed: #{error.message}"
      @logger.debug "Callback error details: #{error.class} - #{error.message}"
      @logger.debug error.backtrace.join("\n")
    end

    def handle_yaml_parsing_error(error, yaml_content)
      @logger.error "YAML parsing error: #{error.message}"
      @logger.debug "Raw YAML content: #{yaml_content}"
      raise "YAML parsing failed: #{error.message}"
    end

    def handle_config_update_error(error)
      @logger.error "Configuration update failed: #{error.message}"
      @logger.debug "Config update error details: #{error.class} - #{error.message}"
      raise error
    end

    # Build configuration parameters for Nacos API request
    # @return [Hash] Configuration parameters
    def config_params
      params = {
        dataId: @config.nacos_data_id,
        group: @config.nacos_group
      }

      add_namespace_param(params)
      add_authentication_params(params)

      @logger.debug "Request params: #{params.inspect}"
      params
    end

    def add_namespace_param(params)
      return unless @config.nacos_namespace && !@config.nacos_namespace.empty?

      params[:tenant] = @config.nacos_namespace
    end

    def add_authentication_params(params)
      return unless @config.nacos_username && @config.nacos_password

      params[:username] = @config.nacos_username
      params[:password] = @config.nacos_password
    end
  end
end
