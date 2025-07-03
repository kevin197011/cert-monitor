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
        is_wildcard = check_wildcard_cert(cert)
        san_domains = extract_san_domains(cert)

        @logger.info "Domain #{domain}: #{expire_days} days until expiry (#{is_wildcard ? 'Wildcard' : 'Single Domain'} Certificate)"
        @logger.debug "SAN domains: #{san_domains.join(', ')}" unless san_domains.empty?

        {
          domain: domain,
          status: :ok,
          expire_days: expire_days,
          issuer: cert.issuer.to_s,
          subject: cert.subject.to_s,
          valid_from: cert.not_before,
          valid_to: cert.not_after,
          is_wildcard: is_wildcard,
          san_domains: san_domains
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

    # Check if certificate is a wildcard certificate
    # @param cert [OpenSSL::X509::Certificate] The SSL certificate
    # @return [Boolean] true if wildcard certificate
    def check_wildcard_cert(cert)
      # 检查主域名是否为泛域名
      common_name = cert.subject.to_a.find { |name, _, _| name == 'CN' }&.at(1)
      return true if common_name&.start_with?('*.')

      # 检查SAN中是否包含泛域名
      san_domains = extract_san_domains(cert)
      san_domains.any? { |domain| domain.start_with?('*.') }
    end

    # Extract Subject Alternative Names from certificate
    # @param cert [OpenSSL::X509::Certificate] The SSL certificate
    # @return [Array<String>] List of SAN domains
    def extract_san_domains(cert)
      cert.extensions.find { |ext| ext.oid == 'subjectAltName' }&.value.to_s
          .split(',')
          .map(&:strip)
          .select { |name| name.start_with?('DNS:') }
          .map { |name| name.gsub('DNS:', '') } || []
    end
  end
end
