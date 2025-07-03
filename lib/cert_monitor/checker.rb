# frozen_string_literal: true

require 'concurrent'

module CertMonitor
  # Domain certificate checker class
  # Handles concurrent domain certificate checking and metrics updates
  class Checker
    CERT_SOURCE = 'remote'

    def initialize
      @config = Config
      @logger = Logger.create('Checker')
      @semaphore = Concurrent::Semaphore.new(@config.max_concurrent_checks || 50)
      @cert_client = CertClient.new
    end

    # Check SSL certificate for a single domain
    # @param domain [String] The domain to check
    # @return [Hash] Certificate information or error details
    def check_domain(domain)
      @logger.info "Starting SSL check for domain: #{domain}"
      @semaphore.acquire
      begin
        result = @cert_client.check_domain(domain)

        # 更新指标
        if result[:status] == :ok
          Exporter.update_cert_status(domain, true, source: CERT_SOURCE)
          Exporter.update_expire_days(domain, result[:expire_days], source: CERT_SOURCE)
          Exporter.update_cert_type(domain, result[:is_wildcard], source: CERT_SOURCE)
          Exporter.update_san_count(domain, result[:san_domains].length, source: CERT_SOURCE)

          cert_type = result[:is_wildcard] ? 'Wildcard' : 'Single Domain'
          @logger.info "Domain #{domain}: #{cert_type} certificate with #{result[:san_domains].length} SANs"
        else
          Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
        end

        result
      rescue StandardError => e
        @logger.error "Failed to check domain #{domain}: #{e.message}"

        # 更新错误状态指标
        Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
        {
          domain: domain,
          status: :error,
          error: e.message,
          source: CERT_SOURCE
        }
      ensure
        @semaphore.release
      end
    end

    # Check SSL certificates for all configured domains
    # Uses concurrent processing with a maximum number of concurrent checks
    # @return [Array<Hash>] Array of certificate check results
    def check_all_domains
      domains = @config.domains || []

      promises = domains.map do |domain|
        Concurrent::Promise.execute do
          check_domain(domain)
        end
      end

      promises.map(&:value!)
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
