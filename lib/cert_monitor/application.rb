# frozen_string_literal: true

require 'logger'
require 'concurrent'

module CertMonitor
  # Main application class that handles initialization and startup
  class Application
    attr_reader :logger, :nacos_client, :checker

    def initialize
      @logger = Logger.new($stdout)
      @logger.level = Logger::INFO # 初始设置为 INFO，后续从配置更新
    end

    def start
      logger.debug 'Starting application...'
      setup_configuration
      setup_logger
      setup_components
      start_nacos_client

      # 首次同步检查
      logger.info 'Performing initial certificate check...'
      @checker.check_all_domains

      # 启动异步检查线程
      start_checker_thread

      # 启动指标服务器
      start_exporter
    rescue StandardError => e
      logger.error "Startup failed: #{e.message}"
      logger.error e.backtrace.join("\n")
      exit 1
    end

    private

    def setup_configuration
      logger.debug 'Loading configuration...'
      Config.load
      logger.debug "Configuration loaded: #{Config.inspect}"
    end

    def setup_logger
      logger.debug 'Setting up logger...'
      # 从配置中读取日志级别
      log_level = (Config.log_level || 'info').upcase
      @logger.level = Logger.const_get(log_level)
      logger.info 'Configuration loaded successfully'
      logger.info "Will fetch domain list from Nacos: #{Config.nacos_addr}"
      logger.info "Log level set to: #{log_level}"
    end

    def setup_components
      logger.debug 'Initializing components...'
      @checker = Checker.new
      logger.debug 'Checker initialized'
    end

    def start_nacos_client
      logger.debug 'Starting Nacos client...'
      @nacos_client = NacosClient.new
      @nacos_client.start_listening
      logger.debug 'Nacos client started'
    end

    def start_checker_thread
      logger.debug 'Starting checker thread...'
      Thread.new do
        # 等待一个检查周期后开始异步检查
        sleep Config.check_interval

        loop do
          logger.debug 'Running certificate check cycle...'
          # 使用 Promise 进行异步检查
          Concurrent::Promise.execute do
            @checker.check_all_domains
          end.on_success do |_|
            logger.debug 'Certificate check cycle completed successfully'
          end.on_error do |error|
            logger.error "Certificate check cycle failed: #{error.message}"
            logger.error error.backtrace.join("\n")
          end

          # 等待下一个检查周期
          sleep Config.check_interval
        rescue StandardError => e
          logger.error "Checker thread error: #{e.message}"
          logger.error e.backtrace.join("\n")
          sleep [Config.check_interval, 10].max
        end
      end
    end

    def start_exporter
      logger.debug 'Starting metrics exporter...'
      logger.info "Starting monitoring service on port: #{Config.port}"
      Exporter.run! host: '0.0.0.0', port: Config.port
    end
  end
end
