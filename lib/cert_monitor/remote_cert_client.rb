# frozen_string_literal: true

module CertMonitor
  # Remote SSL certificate client class
  # Handles SSL certificate checking and expiry calculation for remote domains
  class RemoteCertClient
    CERT_SOURCE = 'remote'

    def initialize
      @config = Config
      @logger = Logger.create('RemoteCert')
      initialize_concurrency_control
      log_initialization_info
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

      update_concurrent_limit
      domains = @config.domains || []

      return [] if domains.empty?

      process_domain_checks(domains)
    end

    # Check SSL certificate for a single domain
    # @param domain [String] The domain to check
    # @return [Hash] Certificate information or error details
    def check_domain(domain)
      @logger.debug "Starting SSL check for domain: #{domain}"
      start_time = Time.now

      begin
        cert_data = establish_ssl_connection(domain)
        return build_error_result(domain, 'SSL connection failed', start_time) unless cert_data

        cert = cert_data[:cert]
        cert_data[:ssl_client]
        cert_data[:tcp_client]

        result = build_certificate_result(domain, cert, start_time)
        log_certificate_details(domain, cert, result)

        result
      rescue StandardError => e
        handle_ssl_check_error(domain, e, start_time)
      ensure
        close_connections(domain)
      end
    end

    private

    def initialize_concurrency_control
      @current_max_concurrent = @config.max_concurrent_checks || 50
      @semaphore = Concurrent::Semaphore.new(@current_max_concurrent)
    end

    def log_initialization_info
      @logger.debug "RemoteCertClient initialized with max_concurrent_checks: #{@current_max_concurrent}"
    end

    def process_domain_checks(domains)
      @logger.info "Found #{domains.length} domains, processing with max #{@current_max_concurrent} concurrent connections"
      @logger.debug "Domains to check: #{domains.inspect}"
      @logger.debug "Connect timeout: #{@config.connect_timeout}s"

      start_time = Time.now

      promises = create_domain_promises(domains)
      results = wait_for_promises(promises)

      log_processing_results(results, start_time)
      results
    end

    def create_domain_promises(domains)
      domains.map do |domain|
        Concurrent::Promise.execute do
          process_domain_check(domain)
        end
      end
    end

    def wait_for_promises(promises)
      @logger.debug "Waiting for #{promises.length} concurrent domain checks to complete..."
      promises.map(&:value!).compact
    end

    def log_processing_results(results, start_time)
      end_time = Time.now
      duration = (end_time - start_time).round(2)

      @logger.info "Completed checking #{results.length} valid remote certificates in #{duration}s"
      @logger.debug "Results summary: #{results.map { |r| "#{r[:domain]}:#{r[:status]}" }.join(', ')}"
    end

    def establish_ssl_connection(domain)
      context = create_ssl_context
      @logger.debug "Connecting to #{domain}:443 with timeout #{context.timeout}s"

      tcp_client = TCPSocket.new(domain, 443)
      ssl_client = OpenSSL::SSL::SSLSocket.new(tcp_client, context)
      ssl_client.hostname = domain
      ssl_client.connect

      @logger.debug "SSL connection established for #{domain}"
      cert = ssl_client.peer_cert

      {
        cert: cert,
        ssl_client: ssl_client,
        tcp_client: tcp_client
      }
    rescue StandardError => e
      @logger.error "Failed to establish SSL connection for #{domain}: #{e.message}"
      nil
    end

    def create_ssl_context
      context = OpenSSL::SSL::SSLContext.new
      context.timeout = @config.connect_timeout || 10
      context
    end

    def build_certificate_result(domain, cert, start_time)
      expire_days = days_until_expire(cert)
      is_wildcard = check_wildcard_cert(cert)
      san_domains = extract_san_domains(cert)
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
    end

    def build_error_result(domain, error_message, start_time)
      duration = (Time.now - start_time).round(3)
      {
        domain: domain,
        status: :error,
        error: error_message,
        error_class: 'ConnectionError',
        source: CERT_SOURCE,
        check_duration: duration
      }
    end

    def log_certificate_details(domain, cert, result)
      cert_type = result[:is_wildcard] ? 'Wildcard' : 'Single Domain'
      @logger.debug "Domain #{domain}: #{result[:expire_days]} days until expiry (#{cert_type} Certificate)"
      @logger.debug "Certificate issuer: #{cert.issuer}"
      @logger.debug "Certificate subject: #{cert.subject}"
      @logger.debug "Certificate valid from: #{cert.not_before}"
      @logger.debug "Certificate valid to: #{cert.not_after}"
      @logger.debug "SAN domains: #{result[:san_domains].join(', ')}" unless result[:san_domains].empty?
    end

    def handle_ssl_check_error(domain, error, start_time)
      duration = (Time.now - start_time).round(3)
      @logger.error "Failed to check domain #{domain}: #{error.message}"
      @logger.debug "Error details: #{error.class} - #{error.message}"
      @logger.debug "Error backtrace: #{error.backtrace.first(3).join(', ')}"
      @logger.debug "Check duration before error: #{duration}s"

      {
        domain: domain,
        status: :error,
        error: error.message,
        error_class: error.class.to_s,
        source: CERT_SOURCE,
        check_duration: duration
      }
    end

    def close_connections(domain)
      # NOTE: ssl_client and tcp_client are not accessible here in the current scope
      # They are closed in the ensure block of the calling method
      @logger.debug "Connections closed for #{domain}"
    end

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
          handle_successful_domain(cert_data)
        else
          handle_failed_domain(domain, cert_data)
        end

        cert_data
      rescue StandardError => e
        handle_domain_processing_error(domain, e)
        nil
      ensure
        @semaphore.release
        @logger.debug "Semaphore released for domain: #{domain}"
      end
    end

    def handle_successful_domain(cert_data)
      @logger.info "Successfully processed domain: #{cert_data[:domain]} (expire in #{cert_data[:expire_days]} days, type: #{cert_data[:is_wildcard] ? 'Wildcard' : 'Single'})"
      @logger.debug "Domain #{cert_data[:domain]} check result: #{cert_data[:expire_days]} days remaining"

      update_prometheus_metrics(cert_data)
      log_domain_details(cert_data)
    end

    def handle_failed_domain(domain, cert_data)
      error_msg = cert_data ? cert_data[:error] : 'Unknown error'
      @logger.info "Domain check failed: #{domain}, reason: #{error_msg}"
      @logger.error "Failed to check domain #{domain}: #{error_msg}"
      @logger.debug "Updating failed status for domain: #{domain}"
      Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
    end

    def handle_domain_processing_error(domain, error)
      @logger.error "Error processing domain #{domain}: #{error.message}"
      @logger.debug "Processing error details: #{error.class} - #{error.backtrace.first(2).join(', ')}"
      Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
    end

    def update_prometheus_metrics(cert_data)
      @logger.debug "Updating Prometheus metrics for domain: #{cert_data[:domain]}"
      Exporter.update_cert_status(cert_data[:domain], true, source: CERT_SOURCE)
      Exporter.update_expire_days(cert_data[:domain], cert_data[:expire_days], source: CERT_SOURCE)
      Exporter.update_cert_type(cert_data[:domain], cert_data[:is_wildcard], source: CERT_SOURCE)
      Exporter.update_san_count(cert_data[:domain], cert_data[:san_domains].length, source: CERT_SOURCE)
    end

    def log_domain_details(cert_data)
      cert_type = cert_data[:is_wildcard] ? 'Wildcard' : 'Single Domain'
      @logger.info "Remote certificate #{cert_data[:domain]}: #{cert_type} certificate with #{cert_data[:san_domains].length} SANs"
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
      return true if check_cn_wildcard(cert)
      return true if check_san_wildcard(cert)

      @logger.debug 'Single domain certificate detected'
      false
    end

    def check_cn_wildcard(cert)
      common_name = cert.subject.to_a.find { |name, _, _| name == 'CN' }&.at(1)
      @logger.debug "Certificate CN: #{common_name}"

      if common_name&.start_with?('*.')
        @logger.debug "Wildcard certificate detected from CN: #{common_name}"
        return true
      end
      false
    end

    def check_san_wildcard(cert)
      san_domains = extract_san_domains(cert)
      wildcard_sans = san_domains.select { |domain| domain.start_with?('*.') }

      unless wildcard_sans.empty?
        @logger.debug "Wildcard certificate detected from SAN: #{wildcard_sans.join(', ')}"
        return true
      end
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

      san_domains = parse_san_extension(san_extension)
      @logger.debug "Extracted #{san_domains.length} SAN domains: #{san_domains.join(', ')}"
      san_domains
    end

    def parse_san_extension(san_extension)
      san_extension.value.to_s
                   .split(',')
                   .map(&:strip)
                   .select { |name| name.start_with?('DNS:') }
                   .map { |name| name.gsub('DNS:', '') }
    end
  end
end
