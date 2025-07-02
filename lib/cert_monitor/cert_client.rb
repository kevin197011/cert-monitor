# frozen_string_literal: true

require 'openssl'
require 'socket'

module CertMonitor
  # SSL certificate client class
  # Handles SSL certificate checking and expiry calculation
  class CertClient
    def initialize
      @logger = Logger.create('Cert')
    end

    # Check SSL certificate for a single domain
    # @param domain [String] The domain to check
    # @return [Hash] Certificate information or error details
    def check_domain(domain)
      @logger.info "Starting SSL check for domain: #{domain}"
      begin
        context = OpenSSL::SSL::SSLContext.new
        tcp_client = TCPSocket.new(domain, 443)
        ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client, context)
        ssl_client.hostname = domain
        ssl_client.connect
        cert = ssl_client.peer_cert

        expire_days = days_until_expire(cert)
        @logger.info "Domain #{domain}: #{expire_days} days until expiry"

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
        {
          domain: domain,
          status: :error,
          error: e.message
        }
      ensure
        ssl_client&.close
        tcp_client&.close
      end
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
