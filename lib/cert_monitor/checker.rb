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
      @logger.level = Logger.const_get(@config.log_level.upcase)
      @semaphore = Concurrent::Semaphore.new(@config.max_concurrent_checks)
    end

    # Check SSL certificate for a single domain
    # @param domain [String] The domain to check
    # @return [Hash] Certificate information or error details
    def check_domain(domain)
      @semaphore.acquire
      begin
        context = OpenSSL::SSL::SSLContext.new
        tcp_client = TCPSocket.new(domain, 443)
        ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client, context)
        ssl_client.hostname = domain
        ssl_client.connect
        cert = ssl_client.peer_cert

        {
          domain: domain,
          status: :ok,
          expire_days: days_until_expire(cert),
          issuer: cert.issuer.to_s,
          subject: cert.subject.to_s,
          valid_from: cert.not_before,
          valid_to: cert.not_after
        }
      rescue StandardError => e
        @logger.error "Failed to check domain #{domain}: #{e.message}"
        {
          domain: domain,
          status: :error,
          error: e.message
        }
      ensure
        ssl_client&.close
        tcp_client&.close
        @semaphore.release
      end
    end

    # Check SSL certificates for all configured domains
    # Uses concurrent processing with a maximum number of concurrent checks
    # @return [Array<Hash>] Array of certificate check results
    def check_all_domains
      @logger.info "Starting SSL certificate check for #{@config.domains.length} domains (max concurrent: #{@config.max_concurrent_checks})"

      promises = @config.domains.map do |domain|
        Concurrent::Promise.execute do
          check_domain(domain)
        end
      end

      results = promises.map(&:value!)
      @logger.info 'Completed SSL certificate check for all domains'
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
