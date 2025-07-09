# frozen_string_literal: true

module CertMonitor
  # Local certificate client class
  # Handles scanning and monitoring of local SSL certificates
  class LocalCertClient
    CERT_SOURCE = 'local'

    def initialize
      @config = Config
      @logger = Logger.create('LocalCert')
      @cert_path = determine_cert_path
      initialize_concurrency_control
      log_initialization_info
    end

    # Update concurrent check limit dynamically
    def update_concurrent_limit
      new_limit = @config.max_concurrent_checks || 50
      return unless new_limit != @current_max_concurrent

      @logger.info "Updating local cert max concurrent checks from #{@current_max_concurrent} to #{new_limit}"
      @logger.debug "Creating new semaphore with limit: #{new_limit}"
      @semaphore = Concurrent::Semaphore.new(new_limit)
      @current_max_concurrent = new_limit
      @logger.debug 'Local cert concurrent limit update completed'
    end

    # Scan all certificate files in the local directory
    # @return [Array<Hash>] Array of certificate check results
    def scan_all_certs
      @logger.info "Scanning certificates in: #{@cert_path}"

      update_concurrent_limit
      return [] unless validate_cert_directory

      cert_files = find_certificate_files
      return [] if cert_files.empty?

      process_certificate_files(cert_files)
    end

    private

    def determine_cert_path
      docker_path = '/app/certs/ssl'
      local_path = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'certs', 'ssl'))

      cert_path = if Dir.exist?(docker_path)
                    docker_path
                  else
                    local_path
                  end

      @logger.debug "Docker path checked: #{docker_path} (exists: #{Dir.exist?(docker_path)})"
      @logger.debug "Local path checked: #{local_path} (exists: #{Dir.exist?(local_path)})"

      cert_path
    end

    def initialize_concurrency_control
      @current_max_concurrent = @config.max_concurrent_checks || 50
      @semaphore = Concurrent::Semaphore.new(@current_max_concurrent)
    end

    def log_initialization_info
      @logger.info "Initializing LocalCertClient with path: #{@cert_path}"
      @logger.debug "LocalCertClient initialized with max_concurrent_checks: #{@current_max_concurrent}"
    end

    def validate_cert_directory
      unless Dir.exist?(@cert_path)
        @logger.error "Certificate directory not found: #{@cert_path}"
        @logger.debug "Directory check failed for: #{@cert_path}"
        return false
      end
      true
    end

    def find_certificate_files
      cert_files = Dir.glob(File.join(@cert_path, '*.crt'))
      @logger.info "Found #{cert_files.length} certificate files, processing with max #{@current_max_concurrent} concurrent operations"
      @logger.debug "Certificate files found: #{cert_files.inspect}"

      @logger.warn "No .crt files found in #{@cert_path}" if cert_files.empty?

      cert_files
    end

    def process_certificate_files(cert_files)
      start_time = Time.now

      promises = create_certificate_promises(cert_files)
      results = wait_for_promises(promises)

      log_processing_results(results, start_time)
      results
    end

    def create_certificate_promises(cert_files)
      cert_files.map do |path|
        Concurrent::Promise.execute do
          process_certificate_file(path)
        end
      end
    end

    def wait_for_promises(promises)
      @logger.debug "Waiting for #{promises.length} concurrent certificate file checks to complete..."
      promises.map(&:value!).compact
    end

    def log_processing_results(results, start_time)
      end_time = Time.now
      duration = (end_time - start_time).round(2)

      @logger.info "Completed scanning #{results.length} valid certificates in #{duration}s"
      @logger.debug "Local cert results summary: #{results.map { |r| "#{r[:domain]}:#{r[:status]}" }.join(', ')}"
    end

    # Process a single certificate file with concurrency control
    # @param path [String] Path to the certificate file
    # @return [Hash, nil] Certificate information or nil if invalid
    def process_certificate_file(path)
      @logger.debug "Acquiring semaphore for certificate file: #{path}"
      @semaphore.acquire

      begin
        @logger.debug "Semaphore acquired for file: #{path}, starting check..."
        cert_data = check_certificate(path)

        if cert_data
          handle_successful_certificate(cert_data)
        else
          handle_failed_certificate(path)
        end

        cert_data
      rescue StandardError => e
        handle_certificate_processing_error(path, e)
        nil
      ensure
        @semaphore.release
        @logger.debug "Semaphore released for file: #{path}"
      end
    end

    def handle_successful_certificate(cert_data)
      @logger.info "Successfully processed certificate: #{cert_data[:domain]}"
      @logger.debug "Certificate #{cert_data[:domain]} check result: #{cert_data[:expire_days]} days remaining"

      update_prometheus_metrics(cert_data)
      log_certificate_details(cert_data)
    end

    def handle_failed_certificate(path)
      @logger.error "Failed to process certificate file: #{path}"
      domain = extract_domain_from_path(path)
      @logger.debug "Updating failed status for local certificate: #{domain}"
      Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
    end

    def handle_certificate_processing_error(path, error)
      @logger.error "Error processing certificate file #{path}: #{error.message}"
      @logger.debug "Processing error details: #{error.class} - #{error.backtrace.first(2).join(', ')}"
      domain = extract_domain_from_path(path)
      Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
    end

    def update_prometheus_metrics(cert_data)
      @logger.debug "Updating Prometheus metrics for local certificate: #{cert_data[:domain]}"
      Exporter.update_cert_status(cert_data[:domain], true, source: CERT_SOURCE)
      Exporter.update_expire_days(cert_data[:domain], cert_data[:expire_days], source: CERT_SOURCE)
      Exporter.update_cert_type(cert_data[:domain], cert_data[:is_wildcard], source: CERT_SOURCE)
      Exporter.update_san_count(cert_data[:domain], cert_data[:san_domains].length, source: CERT_SOURCE)
    end

    def log_certificate_details(cert_data)
      cert_type = cert_data[:is_wildcard] ? 'Wildcard' : 'Single Domain'
      @logger.info "Local certificate #{cert_data[:domain]}: #{cert_type} certificate with #{cert_data[:san_domains].length} SANs"
    end

    # Extract domain name from certificate path
    # @param path [String] Path to the certificate file
    # @return [String] Domain name
    def extract_domain_from_path(path)
      filename = File.basename(path)
      @logger.debug "Extracting domain from filename: #{filename}"

      if filename.end_with?('.crt')
        domain = filename.gsub(/\.crt$/, '')
        @logger.debug "Domain extracted from filename: #{domain}"
        return domain
      end

      extract_domain_from_certificate_content(path)
    end

    def extract_domain_from_certificate_content(path)
      @logger.debug 'Attempting to extract domain from certificate content'
      begin
        cert = OpenSSL::X509::Certificate.new(File.read(path))
        cn_domain = cert.subject.to_a.find { |name, _, _| name == 'CN' }&.at(1)&.gsub(/^\*\./, '')
        domain = cn_domain || File.basename(path, '.*')
        @logger.debug "Domain extracted from certificate CN: #{domain}"
        domain
      rescue StandardError => e
        handle_domain_extraction_error(e, path)
      end
    end

    def handle_domain_extraction_error(error, path)
      @logger.error "Failed to extract domain from certificate: #{error.message}"
      fallback_domain = File.basename(path, '.*')
      @logger.debug "Using fallback domain: #{fallback_domain}"
      fallback_domain
    end

    # Check a single certificate file
    # @param path [String] Path to the certificate file
    # @return [Hash, nil] Certificate information or nil if invalid
    def check_certificate(path)
      @logger.debug "Checking certificate file: #{path}"
      start_time = Time.now

      return nil unless validate_certificate_file(path)

      cert_data = parse_certificate_file(path)
      return nil unless cert_data

      build_certificate_result(cert_data, path, start_time)
    rescue StandardError => e
      handle_certificate_check_error(path, e, start_time)
      nil
    end

    def validate_certificate_file(path)
      unless File.readable?(path)
        @logger.error "Certificate file not readable: #{path}"
        @logger.debug "File permissions: #{File.stat(path).mode.to_s(8)}" if File.exist?(path)
        return false
      end
      true
    end

    def parse_certificate_file(path)
      file_size = File.size(path)
      @logger.debug "Certificate file size: #{file_size} bytes"

      cert = OpenSSL::X509::Certificate.new(File.read(path))
      domain = extract_domain_from_path(path)
      expire_days = days_until_expire(cert)
      san_domains = extract_san_domains(cert)
      is_wildcard = check_wildcard_cert(cert)
      has_key = check_private_key_exists(path)

      {
        cert: cert,
        domain: domain,
        expire_days: expire_days,
        san_domains: san_domains,
        is_wildcard: is_wildcard,
        has_key: has_key,
        file_size: file_size
      }
    end

    def check_private_key_exists(path)
      key_path = path.gsub(/\.crt$/, '.key')
      has_key = File.exist?(key_path)
      @logger.debug "Private key file #{key_path} exists: #{has_key}"
      has_key
    end

    def build_certificate_result(cert_data, path, start_time)
      cert = cert_data[:cert]
      duration = (Time.now - start_time).round(3)

      log_certificate_check_details(cert_data, cert, duration)

      {
        path: path,
        domain: cert_data[:domain],
        status: :ok,
        expire_days: cert_data[:expire_days],
        has_private_key: cert_data[:has_key],
        issuer: cert.issuer.to_s,
        subject: cert.subject.to_s,
        valid_from: cert.not_before,
        valid_to: cert.not_after,
        is_wildcard: cert_data[:is_wildcard],
        san_domains: cert_data[:san_domains],
        source: CERT_SOURCE,
        file_size: cert_data[:file_size],
        check_duration: duration
      }
    end

    def log_certificate_check_details(cert_data, cert, duration)
      cert_type = cert_data[:is_wildcard] ? 'Wildcard' : 'Single Domain'
      @logger.debug "Local certificate #{cert_data[:domain]}: #{cert_data[:expire_days]} days until expiry (#{cert_type}, private key: #{cert_data[:has_key] ? 'present' : 'missing'})"
      @logger.debug "Certificate issuer: #{cert.issuer}"
      @logger.debug "Certificate subject: #{cert.subject}"
      @logger.debug "Certificate valid from: #{cert.not_before}"
      @logger.debug "Certificate valid to: #{cert.not_after}"
      @logger.debug "Certificate check completed in #{duration}s"
    end

    def handle_certificate_check_error(path, error, start_time)
      duration = (Time.now - start_time).round(3)
      @logger.error "Failed to check certificate #{path}: #{error.message}"
      @logger.debug "Certificate check error details: #{error.class} - #{error.message}"
      @logger.debug "Error backtrace: #{error.backtrace.first(3).join(', ')}"
      @logger.debug "Check duration before error: #{duration}s"
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
    # @param cert [OpenSSL::X509::Certificate] The certificate
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

    # Calculate days until certificate expiration
    # @param cert [OpenSSL::X509::Certificate] The certificate
    # @return [Integer] Number of days until expiration
    def days_until_expire(cert)
      days = ((cert.not_after - Time.now) / (24 * 60 * 60)).to_i
      @logger.debug "Certificate expires in #{days} days (#{cert.not_after})"
      days
    end
  end
end
