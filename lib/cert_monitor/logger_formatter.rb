# frozen_string_literal: true

module CertMonitor
  # Custom logger formatter for consistent log format
  class LoggerFormatter < Logger::Formatter
    def call(severity, time, progname, msg)
      "[#{time.strftime('%Y-%m-%d %H:%M:%S %z')}] #{severity} #{progname}: #{msg}\n"
    end
  end

  # Logger factory for creating consistent loggers
  class LoggerFactory
    def self.create_logger(component)
      logger = Logger.new($stdout)
      logger.formatter = LoggerFormatter.new
      logger.progname = component
      logger
    end
  end
end
