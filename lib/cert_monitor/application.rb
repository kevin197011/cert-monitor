# frozen_string_literal: true

module CertMonitor
  # Main application class that handles initialization and startup
  class Application
    attr_reader :logger, :nacos_client, :checker

    def initialize
      @logger = Logger.create('System')
      @logger.level = ::Logger::INFO # 初始设置为 INFO，后续从配置更新
      @logger.debug 'Application instance created'
    end

    def start
      @logger.info 'Starting cert-monitor application...'
      @logger.debug 'Beginning application startup sequence'

      setup_configuration
      setup_logger
      setup_components
      setup_nacos_callback
      start_nacos_client

      # 首次同步检查
      perform_initial_checks

      # 启动异步检查线程
      start_checker_thread

      # 启动指标服务器
      start_exporter
    rescue StandardError => e
      @logger.error "Startup failed: #{e.message}"
      @logger.error "Startup error details: #{e.class} - #{e.message}"
      @logger.error "Startup error backtrace: #{e.backtrace.join("\n")}"
      exit 1
    end

    private

    def setup_configuration
      @logger.debug 'Loading configuration...'
      start_time = Time.now

      Config.load

      duration = (Time.now - start_time).round(3)
      @logger.debug "Configuration loaded in #{duration}s"
      @logger.debug "Nacos enabled: #{Config.nacos_enabled?}"
      @logger.debug "Configuration source: #{Config.nacos_enabled? ? 'Nacos' : 'Local file'}"
    end

    def setup_logger
      @logger.debug 'Setting up logger...'

      # 从配置中读取日志级别
      log_level = (Config.log_level || 'info').upcase
      @logger.debug "Setting log level to: #{log_level}"
      Logger.update_all_level(::Logger.const_get(log_level))

      # 输出当前配置
      @logger.info 'Current configuration:'
      @logger.info "- Domains: #{Config.domains.join(', ')}"
      @logger.info "- Check interval: #{Config.check_interval}s"
      @logger.info "- Connect timeout: #{Config.connect_timeout}s"
      @logger.info "- Expire threshold days: #{Config.threshold_days}"
      @logger.info "- Max concurrent checks: #{Config.max_concurrent_checks}"
      @logger.info "- Metrics port: #{Config.metrics_port}"
      @logger.info "- Log level: #{Config.log_level}"

      @logger.debug "Logger setup completed with level: #{log_level}"
    end

    def setup_components
      @logger.debug 'Initializing components...'
      start_time = Time.now

      @checker = Checker.new

      duration = (Time.now - start_time).round(3)
      @logger.debug "Components initialized in #{duration}s"
      @logger.debug 'Checker coordinator ready'
    end

    def setup_nacos_callback
      # 设置配置变化回调
      return unless Config.nacos_enabled?

      @logger.debug 'Setting up Nacos configuration change callback...'
      @config_change_callback = proc do
        @logger.info 'Configuration changed! Triggering immediate certificate checks...'
        @logger.debug 'Nacos configuration change callback triggered'
        perform_immediate_checks
      end
      @logger.debug 'Nacos callback configured'
    end

    def start_nacos_client
      if Config.nacos_enabled?
        @logger.info 'Starting Nacos config listener...'
        @logger.debug "Nacos server: #{Config.nacos_addr}"
        @logger.debug "Nacos namespace: #{Config.nacos_namespace}"
        @logger.debug "Nacos group: #{Config.nacos_group}"
        @logger.debug "Nacos data ID: #{Config.nacos_data_id}"

        @nacos_client = NacosClient.new
        @nacos_client.on_config_change_callback = @config_change_callback
        @nacos_client.start_listening
        @logger.debug 'Nacos client started and listening for configuration changes'
      else
        @logger.info 'Nacos not configured, skipping Nacos client startup'
        @logger.debug 'Using local configuration mode'
      end
    end

    def perform_initial_checks
      @logger.info 'Performing initial certificate checks...'
      @logger.debug 'Starting initial comprehensive certificate check'
      perform_comprehensive_check
    end

    def perform_immediate_checks
      # 配置更新后立即执行的检查
      @logger.info 'Executing immediate certificate checks due to configuration change...'
      @logger.debug 'Configuration change triggered immediate check'

      # 异步执行检查，避免阻塞配置更新
      Thread.new do
        @logger.debug 'Starting immediate check thread'
        perform_comprehensive_check
        @logger.info 'Immediate certificate checks completed'
        @logger.debug 'Immediate check thread finished'
      rescue StandardError => e
        @logger.error "Immediate certificate check failed: #{e.message}"
        @logger.debug "Immediate check error details: #{e.class} - #{e.message}"
        @logger.error e.backtrace.join("\n")
      end
    end

    def perform_comprehensive_check
      @logger.debug 'Creating comprehensive check promise'
      start_time = Time.now

      Concurrent::Promise.execute do
        @logger.debug 'Comprehensive check promise started'
        @checker.check_all_certificates
      end.on_success do |results|
        duration = (Time.now - start_time).round(2)
        summary = results[:summary]

        @logger.info 'Comprehensive certificate check completed:'
        @logger.info "- Remote certificates: #{summary[:successful_remote]}/#{summary[:total_remote]} successful"
        @logger.info "- Local certificates: #{summary[:successful_local]}/#{summary[:total_local]} successful"
        @logger.debug "Comprehensive check completed in #{duration}s"

        # 记录详细统计信息
        @logger.debug "Check timestamp: #{summary[:check_timestamp]}"
        @logger.debug "Check duration from summary: #{summary[:check_duration]}s"

        @logger.debug "Check had errors: #{results[:error][:message]}" if results[:error]
      end.on_error do |error|
        duration = (Time.now - start_time).round(2)
        @logger.error "Comprehensive certificate check failed: #{error.message}"
        @logger.debug "Comprehensive check failed after #{duration}s"
        @logger.debug "Check error details: #{error.class} - #{error.message}"
        @logger.error error.backtrace.join("\n")
      end
    end

    def start_checker_thread
      @logger.info 'Starting certificate checker thread...'
      @logger.debug "Check interval: #{Config.check_interval}s"

      Thread.new do
        @logger.debug 'Checker thread started'

        # 等待一个检查周期后开始异步检查
        @logger.debug "Waiting #{Config.check_interval}s before first scheduled check"
        sleep Config.check_interval

        loop do
          @logger.info 'Running scheduled certificate checks...'
          @logger.debug 'Scheduled check triggered'

          Time.now
          perform_comprehensive_check

          # 等待下一个检查周期
          @logger.debug "Scheduled check initiated, waiting #{Config.check_interval}s for next check"
          sleep Config.check_interval
        rescue StandardError => e
          @logger.error "Checker thread error: #{e.message}"
          @logger.debug "Checker thread error details: #{e.class} - #{e.message}"
          @logger.error e.backtrace.join("\n")

          sleep_duration = [Config.check_interval, 10].max
          @logger.debug "Sleeping #{sleep_duration}s after error before retry"
          sleep sleep_duration
        end
      end

      @logger.debug 'Checker thread creation completed'
    end

    def start_exporter
      @logger.debug 'Starting metrics exporter...'
      @logger.debug "Metrics port: #{Config.metrics_port}"
      @logger.debug 'Binding to 0.0.0.0 for external access'

      # 设置 Sinatra 服务器选项
      Exporter.set :port, Config.metrics_port
      @logger.info "Starting metrics server on port #{Config.metrics_port}"
      Exporter.run! host: '0.0.0.0'
    end
  end
end
