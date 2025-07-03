# frozen_string_literal: true

require 'openssl'
require 'find'

module CertMonitor
  # Local certificate checker class
  # Handles scanning and monitoring of local SSL certificates
  class LocalCertChecker
    CERT_SOURCE = 'local'

    def initialize
      @logger = Logger.create('LocalCert')
      # 优先使用Docker路径，如果不存在则使用本地路径
      docker_path = '/app/certs/ssl'
      local_path = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'certs', 'ssl'))

      @cert_path = if Dir.exist?(docker_path)
                     docker_path
                   else
                     local_path
                   end

      @logger.info "Initializing LocalCertChecker with path: #{@cert_path}"
    end

    # Scan all certificate files in the local directory
    # @return [Array<Hash>] Array of certificate check results
    def scan_all_certs
      @logger.info "Scanning certificates in: #{@cert_path}"
      results = []

      # 确保目录存在
      unless Dir.exist?(@cert_path)
        @logger.error "Certificate directory not found: #{@cert_path}"
        return results
      end

      # 使用通配符模式查找所有.crt文件
      cert_files = Dir.glob(File.join(@cert_path, '*.crt'))
      @logger.info "Found #{cert_files.length} certificate files"

      cert_files.each do |path|
        cert_data = check_certificate(path)
        if cert_data
          results << cert_data
          @logger.info "Successfully processed certificate: #{cert_data[:domain]}"

          # 更新 Prometheus 指标，使用本地源标识
          Exporter.update_cert_status(cert_data[:domain], true, source: CERT_SOURCE)
          Exporter.update_expire_days(cert_data[:domain], cert_data[:expire_days], source: CERT_SOURCE)
          Exporter.update_cert_type(cert_data[:domain], cert_data[:is_wildcard], source: CERT_SOURCE)
          Exporter.update_san_count(cert_data[:domain], cert_data[:san_domains].length, source: CERT_SOURCE)

          cert_type = cert_data[:is_wildcard] ? 'Wildcard' : 'Single Domain'
          @logger.info "Local certificate #{cert_data[:domain]}: #{cert_type} certificate with #{cert_data[:san_domains].length} SANs"
        end
      rescue StandardError => e
        @logger.error "Error processing certificate file #{path}: #{e.message}"
        domain = extract_domain_from_path(path)
        Exporter.update_cert_status(domain, false, source: CERT_SOURCE)
      end

      @logger.info "Completed scanning #{results.length} valid certificates"
      results
    end

    private

    # Extract domain name from certificate path
    # @param path [String] Path to the certificate file
    # @return [String] Domain name
    def extract_domain_from_path(path)
      # 从文件名中提取域名
      # 例如: /app/certs/ssl/example.com.crt 或 ./certs/ssl/example.com.crt -> example.com
      filename = File.basename(path)
      return filename.gsub(/\.crt$/, '') if filename.end_with?('.crt')

      # 如果无法从文件名提取，则从证书中读取
      cert = OpenSSL::X509::Certificate.new(File.read(path))
      cert.subject.to_a.find { |name, _, _| name == 'CN' }&.at(1)&.gsub(/^\*\./, '') ||
        File.basename(path, '.*')
    end

    # Check a single certificate file
    # @param path [String] Path to the certificate file
    # @return [Hash, nil] Certificate information or nil if invalid
    def check_certificate(path)
      # 检查文件是否可读
      unless File.readable?(path)
        @logger.error "Certificate file not readable: #{path}"
        return nil
      end

      cert = OpenSSL::X509::Certificate.new(File.read(path))
      domain = extract_domain_from_path(path)
      expire_days = days_until_expire(cert)
      san_domains = extract_san_domains(cert)
      is_wildcard = check_wildcard_cert(cert)

      # 检查对应的私钥文件是否存在
      key_path = path.gsub(/\.crt$/, '.key')
      has_key = File.exist?(key_path)

      cert_type = is_wildcard ? 'Wildcard' : 'Single Domain'
      @logger.info "Local certificate #{domain}: #{expire_days} days until expiry (#{cert_type}, private key: #{has_key ? 'present' : 'missing'})"

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
        source: CERT_SOURCE
      }
    rescue StandardError => e
      @logger.error "Failed to check certificate #{path}: #{e.message}"
      nil
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
    # @param cert [OpenSSL::X509::Certificate] The certificate
    # @return [Array<String>] List of SAN domains
    def extract_san_domains(cert)
      cert.extensions.find { |ext| ext.oid == 'subjectAltName' }&.value.to_s
          .split(',')
          .map(&:strip)
          .select { |name| name.start_with?('DNS:') }
          .map { |name| name.gsub('DNS:', '') } || []
    end

    # Calculate days until certificate expiration
    # @param cert [OpenSSL::X509::Certificate] The certificate
    # @return [Integer] Number of days until expiration
    def days_until_expire(cert)
      ((cert.not_after - Time.now) / (24 * 60 * 60)).to_i
    end
  end
end
