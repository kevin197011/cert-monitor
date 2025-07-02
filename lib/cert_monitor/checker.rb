# frozen_string_literal: true

require 'openssl'
require 'socket'
require 'concurrent'

module CertMonitor
  # SSL certificate checker class
  # Handles checking SSL certificates for multiple domains with concurrency control
  class Checker
    def initialize
      @config = Config
      @logger = Logger.new($stdout)
      @logger.level = Logger.const_get((@config.log_level || 'info').upcase)
      @semaphore = Concurrent::Semaphore.new(@config.max_concurrent_checks || 50)
    end

    # Check SSL certificate for a single domain
    # @param domain [String] The domain to check
    # @return [Hash] Certificate information or error details
    def check_domain(domain)
      @logger.debug "Starting certificate check for domain: #{domain}"
      @semaphore.acquire
      begin
        @logger.debug "Establishing SSL connection to #{domain}"
        context = OpenSSL::SSL::SSLContext.new
        tcp_client = TCPSocket.new(domain, 443)
        ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client, context)
        ssl_client.hostname = domain
        ssl_client.connect
        cert = ssl_client.peer_cert

        expire_days = days_until_expire(cert)
        @logger.debug "Certificate check successful for #{domain}, expires in #{expire_days} days"

        # 更新指标
        @logger.debug "Updating metrics for #{domain} (status: true, expire_days: #{expire_days})"
        Exporter.update_cert_status(domain, true)
        Exporter.update_expire_days(domain, expire_days)

        {
          domain: domain,
          status: :ok,
          expire_days: expire_days,
          issuer: cert.issuer.to_s,
          subject: cert.subject.to_s,
          valid_from: cert.not_before,
          valid_to: cert.not_after
        }
      rescue StandardError => e
        @logger.error "Failed to check domain #{domain}: #{e.message}"
        @logger.debug "Error details: #{e.backtrace.join("\n")}"

        # 更新错误状态指标
        @logger.debug "Updating error metrics for #{domain}"
        Exporter.update_cert_status(domain, false)
        {
          domain: domain,
          status: :error,
          error: e.message
        }
      ensure
        ssl_client&.close
        tcp_client&.close
        @semaphore.release
        @logger.debug "Completed certificate check for domain: #{domain}"
      end
    end

    # Check SSL certificates for all configured domains
    # Uses concurrent processing with a maximum number of concurrent checks
    # @return [Array<Hash>] Array of certificate check results
    def check_all_domains
      domains = @config.domains || []
      @logger.debug "Current domains configuration: #{domains.inspect}"
      @logger.info "Starting SSL certificate check for #{domains.length} domains (max concurrent: #{@config.max_concurrent_checks})"

      promises = domains.map do |domain|
        @logger.debug "Creating promise for domain: #{domain}"
        Concurrent::Promise.execute do
          check_domain(domain)
        end
      end

      @logger.debug 'Waiting for all domain checks to complete...'
      results = promises.map(&:value!)
      @logger.info 'Completed SSL certificate check for all domains'
      @logger.debug "Check results: #{results.inspect}"
      results
    end

    private

    # Calculate the number of days until certificate expiration
    # @param cert [OpenSSL::X509::Certificate] The SSL certificate
    # @return [Integer] Number of days until expiration
    def days_until_expire(cert)
      ((cert.not_after - Time.now) / (24 * 60 * 60)).to_i
    end
  end
end
