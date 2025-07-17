# frozen_string_literal: true

module CertMonitor
  module Utils
    # 获取全局 logger
    def self.logger
      require_relative 'logger'
      @logger ||= CertMonitor::Logger.create('Utils')
    end

    # 优雅重启 Puma 主进程
    # @param pidfile [String] Puma 主进程 pid 文件路径，默认 'tmp/pids/puma.pid'
    # @return [Boolean] 是否成功触发重启
    #
    # Docker 场景推荐在应用启动时调用 write_pid_file，确保 pid 文件存在
    def self.restart_puma(pidfile = 'tmp/pids/puma.pid')
      unless File.exist?(pidfile)
        logger.warn "Puma pidfile not found: #{pidfile}"
        return false
      end

      pid = File.read(pidfile).strip.to_i
      if pid <= 0
        logger.warn "Invalid Puma pid: #{pid}"
        return false
      end

      Process.kill('USR2', pid)
      logger.info "Puma restart signal sent to pid: #{pid}"
      true
    rescue Errno::ESRCH
      logger.warn "No Puma process found with pid: #{pid}"
      false
    rescue StandardError => e
      logger.error "Failed to restart Puma: #{e.class} - #{e.message}"
      false
    end

    # 写入当前进程 pid 到指定文件（默认 tmp/pids/puma.pid）
    # @param pidfile [String] 目标 pid 文件路径
    # @return [Boolean] 是否写入成功
    def self.write_pid_file(pidfile = 'tmp/pids/puma.pid')
      require 'fileutils'
      FileUtils.mkdir_p(File.dirname(pidfile))
      File.write(pidfile, Process.pid)
      logger.info "Wrote pid #{Process.pid} to file: #{pidfile}"
      true
    rescue StandardError => e
      logger.error "Failed to write pid file: #{e.class} - #{e.message}"
      false
    end
  end
end
