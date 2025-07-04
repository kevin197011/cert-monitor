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

      @logger.info 'Starting Nacos config listener...'
      @logger.debug "Configuration details: dataId=#{@config.nacos_data_id}, group=#{@config.nacos_group}, namespace=#{@config.nacos_namespace}"
      @logger.debug "Nacos server: #{@config.nacos_addr}"
      @logger.info "Initial polling interval: #{@config.nacos_poll_interval} seconds"

      Thread.new do
        while @running.true?
          begin
            check_config_update
            # Use the potentially updated poll interval from Nacos config
            sleep @config.nacos_poll_interval
          rescue StandardError => e
            @logger.error "Configuration update error: #{e.message}"
            @logger.debug e.backtrace.join("\n")
            sleep [@config.nacos_poll_interval, 10].max # Use max of poll interval or 10 seconds on error
          end
        end
      end
    end

    # Stop listening for configuration changes
    def stop_listening
      @running.make_false
      @logger.info 'Nacos config listener stopped'
    end

    private

    # Check for configuration updates from Nacos
    # Uses MD5 hash to detect changes and updates local configuration if needed
    def check_config_update
      uri = URI.join(@config.nacos_addr, '/nacos/v1/cs/configs')
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 10
      http.open_timeout = 5

      # Use GET request with parameters
      uri.query = URI.encode_www_form(config_params)
      @logger.debug "Requesting config from: #{uri}"

      response = http.get(uri.request_uri)
      @logger.debug "Response status: #{response.code}"

      if response.is_a?(Net::HTTPSuccess)
        yaml_content = response.body
        @logger.debug "Raw response body length: #{yaml_content.length}"
        @logger.debug "Raw response body content: #{yaml_content}"

        # Check if response is empty or contains error
        if yaml_content.nil? || yaml_content.strip.empty?
          @logger.warn 'Received empty configuration from Nacos'
          return
        end

        current_md5 = Digest::MD5.hexdigest(yaml_content)
        @logger.info "Content MD5: #{current_md5}, Last MD5: #{@last_md5}"

        if @last_md5 != current_md5
          @last_md5 = current_md5
          begin
            config_data = YAML.safe_load(yaml_content)
            @logger.debug "Parsed YAML config: #{config_data.inspect}"
            @logger.debug "Config data class: #{config_data.class}"

            if config_data.is_a?(Hash)
              @logger.debug "Domains in config: #{config_data['domains'].inspect}"
              @logger.debug "Settings in config: #{config_data['settings'].inspect}"

              if @config.update_app_config(config_data)
                @logger.info 'Configuration updated successfully'
                @logger.debug "Current configuration: metrics_port=#{@config.metrics_port}, check_interval=#{@config.check_interval}s"
                @logger.debug "Monitored domains: #{@config.domains.inspect}"

                # Update logger level if it changed
                if config_data['settings'] && config_data['settings']['log_level']
                  new_log_level = config_data['settings']['log_level'].upcase
                  Logger.update_all_level(::Logger.const_get(new_log_level))
                  @logger.info "Log level updated to: #{new_log_level}"
                  @logger.debug "Current metrics port: #{@config.metrics_port}"
                end

                # 触发配置变化回调
                if @on_config_change_callback
                  @logger.debug 'Triggering config change callback...'
                  begin
                    @on_config_change_callback.call
                  rescue StandardError => e
                    @logger.error "Config change callback failed: #{e.message}"
                    @logger.debug e.backtrace.join("\n")
                  end
                end
              else
                @logger.error 'Failed to update configuration'
              end
            else
              @logger.error "Invalid configuration format: expected Hash, got #{config_data.class}"
              @logger.debug "Raw config data: #{config_data.inspect}"
              raise 'Invalid configuration format: not a valid YAML configuration'
            end
          rescue Psych::SyntaxError => e
            @logger.error "YAML parsing error: #{e.message}"
            @logger.debug "Raw YAML content: #{yaml_content}"
            raise "YAML parsing failed: #{e.message}"
          end
        else
          @logger.info 'Configuration unchanged (same MD5)'
        end
      else
        @logger.error "Failed to fetch configuration: HTTP #{response.code} - #{response.body}"
        raise "Failed to fetch configuration: HTTP #{response.code}"
      end
    end

    # Build configuration parameters for Nacos API request
    # @return [Hash] Configuration parameters
    def config_params
      params = {
        dataId: @config.nacos_data_id,
        group: @config.nacos_group
      }

      # Add namespace if specified
      params[:tenant] = @config.nacos_namespace if @config.nacos_namespace && !@config.nacos_namespace.empty?

      # Add authentication if credentials are provided
      if @config.nacos_username && @config.nacos_password
        params[:username] = @config.nacos_username
        params[:password] = @config.nacos_password
      end

      @logger.debug "Request params: #{params.inspect}"
      params
    end
  end
end
