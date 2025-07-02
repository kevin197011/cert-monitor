# frozen_string_literal: true

require 'net/http'
require 'concurrent'
require 'logger'
require 'digest'
require 'uri'
require 'json'
require 'yaml'

module CertMonitor
  # Nacos configuration client class
  # Handles communication with Nacos configuration center and configuration updates
  class NacosClient
    def initialize
      @config = Config
      @logger = LoggerFactory.create_logger('Nacos')
      @logger.level = Logger.const_get((@config.log_level || 'info').upcase)
      @last_md5 = nil
      @running = Concurrent::AtomicBoolean.new(false)
    end

    # Start listening for configuration changes from Nacos
    # Runs in a separate thread and periodically checks for updates
    def start_listening
      return if @running.true?

      @running.make_true

      @logger.info 'Starting Nacos config listener...'
      @logger.debug "Configuration details: dataId=#{@config.nacos_data_id}, group=#{@config.nacos_group}, namespace=#{@config.nacos_namespace}"
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
      uri = URI.join(@config.nacos_addr, '/nacos/v2/cs/config')
      uri.query = URI.encode_www_form(config_params)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 10
      http.open_timeout = 5

      response = http.get(uri.request_uri)

      if response.is_a?(Net::HTTPSuccess)
        json_response = JSON.parse(response.body)

        if json_response['code'].zero? && json_response['data']
          yaml_content = json_response['data']
          current_md5 = Digest::MD5.hexdigest(yaml_content)

          if @last_md5 != current_md5
            @last_md5 = current_md5
            begin
              config_data = YAML.safe_load(yaml_content)
              @logger.debug "Received configuration update: #{config_data.inspect}"

              if config_data.is_a?(Hash)
                if @config.update_app_config(config_data)
                  @logger.info 'Configuration updated successfully'
                  @logger.debug "Current configuration: metrics_port=#{@config.metrics_port}, check_interval=#{@config.check_interval}s"
                  @logger.debug "Monitored domains: #{@config.domains.join(', ')}"

                  # Update logger level if it changed
                  if config_data['settings'] && config_data['settings']['log_level']
                    new_log_level = config_data['settings']['log_level'].upcase
                    @logger.level = Logger.const_get(new_log_level)
                    @logger.info "Log level updated to: #{new_log_level}"
                    @logger.debug "Current metrics port: #{@config.metrics_port}"
                  end
                end
              else
                @logger.error "Invalid configuration format: expected Hash, got #{config_data.class}"
                raise 'Invalid configuration format: not a valid YAML configuration'
              end
            rescue Psych::SyntaxError => e
              @logger.error "YAML parsing error: #{e.message}"
              @logger.debug "Raw YAML content: #{yaml_content}"
              raise "YAML parsing failed: #{e.message}"
            end
          end
        else
          error_msg = json_response['message'] || 'Unknown error'
          @logger.error "Failed to fetch configuration: #{error_msg}"
          raise "Failed to fetch configuration: #{error_msg}"
        end
      else
        @logger.error "Failed to fetch configuration: HTTP #{response.code}"
        raise "Failed to fetch configuration: HTTP #{response.code}"
      end
    end

    # Build configuration parameters for Nacos API request
    # @return [Hash] Configuration parameters
    def config_params
      {
        dataId: @config.nacos_data_id,
        group: @config.nacos_group,
        namespaceId: @config.nacos_namespace
      }
    end
  end
end
