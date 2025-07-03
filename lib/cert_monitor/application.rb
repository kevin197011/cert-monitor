# frozen_string_literal: true

require 'concurrent'

module CertMonitor
  # Main application class that handles initialization and startup
  class Application
    attr_reader :logger, :nacos_client, :checker, :local_checker

    def initialize
      @logger = Logger.create('System')
      @logger.level = ::Logger::INFO # 初始设置为 INFO，后续从配置更新
    end

    def start
      logger.debug 'Starting application...'
      setup_configuration
      setup_logger
      setup_components
      start_nacos_client

      # 首次同步检查
      logger.info 'Starting domain checker...'
      @checker.check_all_domains

      # 首次本地证书检查
      logger.info 'Starting local certificate checker...'
      @local_checker.scan_all_certs

      # 启动异步检查线程
      start_checker_thread

      # 启动本地证书检查线程
      start_local_checker_thread

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
      Logger.update_all_level(::Logger.const_get(log_level))

      # 输出当前配置
      logger.info 'Current configuration:'
      logger.info "- Domains: #{Config.domains.join(', ')}"
      logger.info "- Check interval: #{Config.check_interval}s"
      logger.info "- Connect timeout: #{Config.connect_timeout}s"
      logger.info "- Expire threshold days: #{Config.threshold_days}"
      logger.info "- Max concurrent checks: #{Config.max_concurrent_checks}"
      logger.info "- Metrics port: #{Config.metrics_port}"
      logger.info "- Log level: #{Config.log_level}"
    end

    def setup_components
      logger.debug 'Initializing components...'
      @checker = Checker.new
      @local_checker = LocalCertChecker.new
      logger.debug 'Components initialized'
    end

    def start_nacos_client
      logger.info 'Starting Nacos config listener...'
      @nacos_client = NacosClient.new
      @nacos_client.start_listening
    end

    def start_checker_thread
      logger.info 'Starting online certificate checker thread...'
      Thread.new do
        # 等待一个检查周期后开始异步检查
        sleep Config.check_interval

        loop do
          logger.info "Checking #{Config.domains.length} online domains..."
          # 使用 Promise 进行异步检查
          Concurrent::Promise.execute do
            @checker.check_all_domains
          end.on_success do |results|
            successful_checks = results.count { |r| r[:status] == :ok }
            logger.info "Online domain check completed: #{successful_checks}/#{results.length} successful"
          end.on_error do |error|
            logger.error "Online certificate check cycle failed: #{error.message}"
            logger.error error.backtrace.join("\n")
          end

          # 等待下一个检查周期
          sleep Config.check_interval
        rescue StandardError => e
          logger.error "Online checker thread error: #{e.message}"
          logger.error e.backtrace.join("\n")
          sleep [Config.check_interval, 10].max
        end
      end
    end

    def start_local_checker_thread
      logger.info 'Starting local certificate checker thread...'
      Thread.new do
        # 等待30秒后开始本地证书检查
        sleep 30

        loop do
          logger.info 'Scanning local certificates...'
          # 使用 Promise 进行异步检查
          Concurrent::Promise.execute do
            @local_checker.scan_all_certs
          end.on_success do |results|
            valid_certs = results.count { |r| r && r[:status] == :ok }
            logger.info "Local certificate scan completed: #{valid_certs}/#{results.length} valid certificates found"
          end.on_error do |error|
            logger.error "Local certificate scan failed: #{error.message}"
            logger.error error.backtrace.join("\n")
          end

          # 每5分钟检查一次本地证书
          sleep 300
        rescue StandardError => e
          logger.error "Local checker thread error: #{e.message}"
          logger.error e.backtrace.join("\n")
          sleep 300 # 发生错误时等待5分钟
        end
      end
    end

    def start_exporter
      logger.debug 'Starting metrics exporter...'
      # 设置 Sinatra 服务器选项
      Exporter.set :port, Config.metrics_port
      Exporter.run! host: '0.0.0.0'
    end
  end
end
