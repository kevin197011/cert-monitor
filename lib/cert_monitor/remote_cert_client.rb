# frozen_string_literal: true

module CertMonitor
  # Remote SSL certificate client class
  # Handles SSL certificate checking and expiry calculation for remote domains
  class RemoteCertClient
    CERT_SOURCE = 'remote'

    def initialize
      @config = Config
      @logger = Logger.create('RemoteCert')

      # 初始化并发控制
      @semaphore = Concurrent::Semaphore.new(@config.max_concurrent_checks || 50)
      @current_max_concurrent = @config.max_concurrent_checks || 50

      @logger.debug "RemoteCertClient initialized with max_concurrent_checks: #{@current_max_concurrent}"
    end

    # Update concurrent check limit dynamically
    def update_concurrent_limit
      new_limit = @config.max_concurrent_checks || 50
      return unless new_limit != @current_max_concurrent

      @logger.info "Updating remote cert max concurrent checks from #{@current_max_concurrent} to #{new_limit}"
      @logger.debug "Creating new semaphore with limit: #{new_limit}"
      @semaphore = Concurrent::Semaphore.new(new_limit)
      @current_max_concurrent = new_limit
      @logger.debug 'Concurrent limit update completed'
    end

    # Check SSL certificates for all configured domains
    # @return [Array<Hash>] Array of certificate check results
    def check_all_domains
      @logger.info 'Checking remote SSL certificates...'

      # 更新并发限制
      update_concurrent_limit

      domains = @config.domains || []

      # 确保有域名需要检查
      if domains.empty?
        @logger.warn 'No domains configured for remote checking'
        @logger.debug 'Config.domains is empty or nil'
        return []
      end

      @logger.info "Found #{domains.length} domains, processing with max #{@current_max_concurrent} concurrent connections"
      @logger.debug "Domains to check: #{domains.inspect}"
      @logger.debug "Connect timeout: #{@config.connect_timeout}s"

      start_time = Time.now

      # 使用并发处理域名
      promises = domains.map do |domain|
        Concurrent::Promise.execute do
          process_domain_check(domain)
        end
      end

      # 等待所有任务完成并收集结果
      @logger.debug "Waiting for #{promises.length} concurrent domain checks to complete..."
      results = promises.map(&:value!).compact

      end_time = Time.now
      duration = (end_time - start_time).round(2)

      @logger.info "Completed checking #{results.length} valid remote certificates in #{duration}s"
      @logger.debug "Results summary: #{results.map { |r| "#{r[:domain]}:#{r[:status]}" }.join(', ')}"

      results
    end

    # Check SSL certificate for a single domain
    # @param domain [String] The domain to check
    # @return [Hash] Certificate information or error details
    def check_domain(domain)
      @logger.debug "Starting SSL check for domain: #{domain}"
      start_time = Time.now

      begin
        context = OpenSSL::SSL::SSLContext.new
        context.timeout = @config.connect_timeout || 10

        @logger.debug "Connecting to #{domain}:443 with timeout #{context.timeout}s"
        tcp_client = TCPSocket.new(domain, 443)
        ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client, context)
        ssl_client.hostname = domain
        ssl_client.connect

        @logger.debug "SSL connection established for #{domain}"
        cert = ssl_client.peer_cert

        expire_days = days_until_expire(cert)
        is_wildcard = check_wildcard_cert(cert)
        san_domains = extract_san_domains(cert)

        cert_type = is_wildcard ? 'Wildcard' : 'Single Domain'
        @logger.debug "Domain #{domain}: #{expire_days} days until expiry (#{cert_type} Certificate)"
        @logger.debug "Certificate issuer: #{cert.issuer}"
        @logger.debug "Certificate subject: #{cert.subject}"
        @logger.debug "Certificate valid from: #{cert.not_before}"
        @logger.debug "Certificate valid to: #{cert.not_after}"
        @logger.debug "SAN domains: #{san_domains.join(', ')}" unless san_domains.empty?

        duration = (Time.now - start_time).round(3)
        @logger.debug "SSL check for #{domain} completed in #{duration}s"

        {
          domain: domain,
          status: :ok,
          expire_days: expire_days,
          issuer: cert.issuer.to_s,
          subject: cert.subject.to_s,
          valid_from: cert.not_before,
          valid_to: cert.not_after,
          is_wildcard: is_wildcard,
          san_domains: san_domains,
          source: CERT_SOURCE,
          check_duration: duration
        }
      rescue StandardError => e
        duration = (Time.now - start_time).round(3)
        @logger.error "Failed to check domain #{domain}: #{e.message}"
        @logger.debug "Error details: #{e.class} - #{e.message}"
        @logger.debug "Error backtrace: #{e.backtrace.first(3).join(', ')}"
        @logger.debug "Check duration before error: #{duration}s"

        {
          domain: domain,
          status: :error,
          error: e.message,
          error_class: e.class.to_s,
          source: CERT_SOURCE,
          check_duration: duration
        }
      ensure
        ssl_client&.close
        tcp_client&.close
        @logger.debug "Connections closed for #{domain}"
      end
    end

    private

    # Process a single domain check with concurrency control
    # @param domain [String] The domain to check
    # @return [Hash, nil] Certificate information or nil if invalid
    def process_domain_check(domain)
      @logger.debug "Acquiring semaphore for domain: #{domain}"
      @semaphore.acquire

      begin
        @logger.debug "Semaphore acquired for domain: #{domain}, starting check..."
        cert_data = check_domain(domain)

        if cert_data && cert_data[:status] == :ok
          @logger.info "Successfully processed domain: #{cert_data[:domain]}"
          @logger.debug "Domain #{domain} check result: #{cert_data[:expire_days]} days remaining"

          # 更新 Prometheus 指标，使用远程源标识
          @logger.debug "Updating Prometheus metrics for domain: #{domain}"
          Exporter.update_cert_status(cert_data[:domain], true, source: CERT_SOURCE)
          Exporter.update_expire_days(cert_data[:domain], cert_data[:expire_days], source: CERT_SOURCE)
          Exporter.update_cert_type(cert_data[:domain], cert_data[:is_wildcard], source: CERT_SOURCE)
          Exporter.update_san_count(cert_data[:domain], cert_data[:san_domains].length, source: CERT_SOURCE)

          cert_type = cert_data[:is_wildcard] ? 'Wildcard' : 'Single Domain'
          @logger.info "Remote certificate #{cert_data[:domain]}: #{cert_type} certificate with #{cert_data[:san_domains].length} SANs"
        else
          error_msg = cert_data ? cert_data[:error] : 'Unknown error'
          @logger.error "Failed to check domain #{domain}: #{error_msg}"
          @logger.debug "Updating failed status for domain: #{domain}"
          Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
        end

        cert_data
      rescue StandardError => e
        @logger.error "Error processing domain #{domain}: #{e.message}"
        @logger.debug "Processing error details: #{e.class} - #{e.backtrace.first(2).join(', ')}"
        Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
        nil
      ensure
        @semaphore.release
        @logger.debug "Semaphore released for domain: #{domain}"
      end
    end

    # Calculate the number of days until certificate expiration
    # @param cert [OpenSSL::X509::Certificate] The SSL certificate
    # @return [Integer] Number of days until expiration
    def days_until_expire(cert)
      days = ((cert.not_after - Time.now) / (24 * 60 * 60)).to_i
      @logger.debug "Certificate expires in #{days} days (#{cert.not_after})"
      days
    end

    # Check if certificate is a wildcard certificate
    # @param cert [OpenSSL::X509::Certificate] The SSL certificate
    # @return [Boolean] true if wildcard certificate
    def check_wildcard_cert(cert)
      # 检查主域名是否为泛域名
      common_name = cert.subject.to_a.find { |name, _, _| name == 'CN' }&.at(1)
      @logger.debug "Certificate CN: #{common_name}"

      if common_name&.start_with?('*.')
        @logger.debug "Wildcard certificate detected from CN: #{common_name}"
        return true
      end

      # 检查SAN中是否包含泛域名
      san_domains = extract_san_domains(cert)
      wildcard_sans = san_domains.select { |domain| domain.start_with?('*.') }

      unless wildcard_sans.empty?
        @logger.debug "Wildcard certificate detected from SAN: #{wildcard_sans.join(', ')}"
        return true
      end

      @logger.debug 'Single domain certificate detected'
      false
    end

    # Extract Subject Alternative Names from certificate
    # @param cert [OpenSSL::X509::Certificate] The SSL certificate
    # @return [Array<String>] List of SAN domains
    def extract_san_domains(cert)
      san_extension = cert.extensions.find { |ext| ext.oid == 'subjectAltName' }

      unless san_extension
        @logger.debug 'No SAN extension found in certificate'
        return []
      end

      san_domains = san_extension.value.to_s
                                 .split(',')
                                 .map(&:strip)
                                 .select { |name| name.start_with?('DNS:') }
                                 .map { |name| name.gsub('DNS:', '') }

      @logger.debug "Extracted #{san_domains.length} SAN domains: #{san_domains.join(', ')}"
      san_domains
    end
  end
end
