# frozen_string_literal: true

module CertMonitor
  # Local certificate client class
  # Handles scanning and monitoring of local SSL certificates
  class LocalCertClient
    CERT_SOURCE = 'local'

    def initialize
      @config = Config
      @logger = Logger.create('LocalCert')
      # 优先使用Docker路径，如果不存在则使用本地路径
      docker_path = '/app/certs/ssl'
      local_path = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'certs', 'ssl'))

      @cert_path = if Dir.exist?(docker_path)
                     docker_path
                   else
                     local_path
                   end

      @logger.info "Initializing LocalCertClient with path: #{@cert_path}"
      @logger.debug "Docker path checked: #{docker_path} (exists: #{Dir.exist?(docker_path)})"
      @logger.debug "Local path checked: #{local_path} (exists: #{Dir.exist?(local_path)})"

      # 初始化并发控制
      @semaphore = Concurrent::Semaphore.new(@config.max_concurrent_checks || 50)
      @current_max_concurrent = @config.max_concurrent_checks || 50

      @logger.debug "LocalCertClient initialized with max_concurrent_checks: #{@current_max_concurrent}"
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

      # 更新并发限制
      update_concurrent_limit

      # 确保目录存在
      unless Dir.exist?(@cert_path)
        @logger.error "Certificate directory not found: #{@cert_path}"
        @logger.debug "Directory check failed for: #{@cert_path}"
        return []
      end

      # 使用通配符模式查找所有.crt文件
      cert_files = Dir.glob(File.join(@cert_path, '*.crt'))
      @logger.info "Found #{cert_files.length} certificate files, processing with max #{@current_max_concurrent} concurrent operations"
      @logger.debug "Certificate files found: #{cert_files.inspect}"

      if cert_files.empty?
        @logger.warn "No .crt files found in #{@cert_path}"
        return []
      end

      start_time = Time.now

      # 使用并发处理证书文件
      promises = cert_files.map do |path|
        Concurrent::Promise.execute do
          process_certificate_file(path)
        end
      end

      # 等待所有任务完成并收集结果
      @logger.debug "Waiting for #{promises.length} concurrent certificate file checks to complete..."
      results = promises.map(&:value!).compact

      end_time = Time.now
      duration = (end_time - start_time).round(2)

      @logger.info "Completed scanning #{results.length} valid certificates in #{duration}s"
      @logger.debug "Local cert results summary: #{results.map { |r| "#{r[:domain]}:#{r[:status]}" }.join(', ')}"

      results
    end

    private

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
          @logger.info "Successfully processed certificate: #{cert_data[:domain]}"
          @logger.debug "Certificate #{cert_data[:domain]} check result: #{cert_data[:expire_days]} days remaining"

          # 更新 Prometheus 指标，使用本地源标识
          @logger.debug "Updating Prometheus metrics for local certificate: #{cert_data[:domain]}"
          Exporter.update_cert_status(cert_data[:domain], true, source: CERT_SOURCE)
          Exporter.update_expire_days(cert_data[:domain], cert_data[:expire_days], source: CERT_SOURCE)
          Exporter.update_cert_type(cert_data[:domain], cert_data[:is_wildcard], source: CERT_SOURCE)
          Exporter.update_san_count(cert_data[:domain], cert_data[:san_domains].length, source: CERT_SOURCE)

          cert_type = cert_data[:is_wildcard] ? 'Wildcard' : 'Single Domain'
          @logger.info "Local certificate #{cert_data[:domain]}: #{cert_type} certificate with #{cert_data[:san_domains].length} SANs"
        else
          @logger.error "Failed to process certificate file: #{path}"
          domain = extract_domain_from_path(path)
          @logger.debug "Updating failed status for local certificate: #{domain}"
          Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
        end

        cert_data
      rescue StandardError => e
        @logger.error "Error processing certificate file #{path}: #{e.message}"
        @logger.debug "Processing error details: #{e.class} - #{e.backtrace.first(2).join(', ')}"
        domain = extract_domain_from_path(path)
        Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
        nil
      ensure
        @semaphore.release
        @logger.debug "Semaphore released for file: #{path}"
      end
    end

    # Extract domain name from certificate path
    # @param path [String] Path to the certificate file
    # @return [String] Domain name
    def extract_domain_from_path(path)
      # 从文件名中提取域名
      # 例如: /app/certs/ssl/example.com.crt 或 ./certs/ssl/example.com.crt -> example.com
      filename = File.basename(path)
      @logger.debug "Extracting domain from filename: #{filename}"

      if filename.end_with?('.crt')
        domain = filename.gsub(/\.crt$/, '')
        @logger.debug "Domain extracted from filename: #{domain}"
        return domain
      end

      # 如果无法从文件名提取，则从证书中读取
      @logger.debug 'Attempting to extract domain from certificate content'
      begin
        cert = OpenSSL::X509::Certificate.new(File.read(path))
        cn_domain = cert.subject.to_a.find { |name, _, _| name == 'CN' }&.at(1)&.gsub(/^\*\./, '')
        domain = cn_domain || File.basename(path, '.*')
        @logger.debug "Domain extracted from certificate CN: #{domain}"
        domain
      rescue StandardError => e
        @logger.error "Failed to extract domain from certificate: #{e.message}"
        fallback_domain = File.basename(path, '.*')
        @logger.debug "Using fallback domain: #{fallback_domain}"
        fallback_domain
      end
    end

    # Check a single certificate file
    # @param path [String] Path to the certificate file
    # @return [Hash, nil] Certificate information or nil if invalid
    def check_certificate(path)
      @logger.debug "Checking certificate file: #{path}"
      start_time = Time.now

      # 检查文件是否可读
      unless File.readable?(path)
        @logger.error "Certificate file not readable: #{path}"
        @logger.debug "File permissions: #{File.stat(path).mode.to_s(8)}" if File.exist?(path)
        return nil
      end

      file_size = File.size(path)
      @logger.debug "Certificate file size: #{file_size} bytes"

      cert = OpenSSL::X509::Certificate.new(File.read(path))
      domain = extract_domain_from_path(path)
      expire_days = days_until_expire(cert)
      san_domains = extract_san_domains(cert)
      is_wildcard = check_wildcard_cert(cert)

      # 检查对应的私钥文件是否存在
      key_path = path.gsub(/\.crt$/, '.key')
      has_key = File.exist?(key_path)
      @logger.debug "Private key file #{key_path} exists: #{has_key}"

      cert_type = is_wildcard ? 'Wildcard' : 'Single Domain'
      duration = (Time.now - start_time).round(3)

      @logger.debug "Local certificate #{domain}: #{expire_days} days until expiry (#{cert_type}, private key: #{has_key ? 'present' : 'missing'})"
      @logger.debug "Certificate issuer: #{cert.issuer}"
      @logger.debug "Certificate subject: #{cert.subject}"
      @logger.debug "Certificate valid from: #{cert.not_before}"
      @logger.debug "Certificate valid to: #{cert.not_after}"
      @logger.debug "Certificate check completed in #{duration}s"

      {
        path: path,
        domain: domain,
        status: :ok,
        expire_days: expire_days,
        has_private_key: has_key,
        issuer: cert.issuer.to_s,
        subject: cert.subject.to_s,
        valid_from: cert.not_before,
        valid_to: cert.not_after,
        is_wildcard: is_wildcard,
        san_domains: san_domains,
        source: CERT_SOURCE,
        file_size: file_size,
        check_duration: duration
      }
    rescue StandardError => e
      duration = (Time.now - start_time).round(3)
      @logger.error "Failed to check certificate #{path}: #{e.message}"
      @logger.debug "Certificate check error details: #{e.class} - #{e.message}"
      @logger.debug "Error backtrace: #{e.backtrace.first(3).join(', ')}"
      @logger.debug "Check duration before error: #{duration}s"
      nil
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
    # @param cert [OpenSSL::X509::Certificate] The certificate
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
