# frozen_string_literal: true

module CertMonitor
  # Prometheus metrics exporter class
  # Handles metrics collection and HTTP endpoint for Prometheus scraping
  class Exporter < Sinatra::Base
    # Initialize Prometheus metrics
    @@prometheus = Prometheus::Client.registry

    # Define metrics
    @@cert_expire_days = @@prometheus.gauge(
      :cert_expire_days,
      docstring: 'Number of days until SSL certificate expires',
      labels: %i[domain source]
    )

    @@cert_status = @@prometheus.gauge(
      :cert_status,
      docstring: 'SSL certificate check status (1=valid, 0=invalid)',
      labels: %i[domain source]
    )

    @@cert_type = @@prometheus.gauge(
      :cert_type,
      docstring: 'SSL certificate type (1=wildcard, 0=single domain)',
      labels: %i[domain source]
    )

    @@cert_san_count = @@prometheus.gauge(
      :cert_san_count,
      docstring: 'Number of Subject Alternative Names in SSL certificate',
      labels: %i[domain source]
    )

    # Metrics endpoint
    get '/metrics' do
      content_type 'text/plain; version=0.0.4'
      Prometheus::Client::Formats::Text.marshal(@@prometheus)
    end

    # Health check endpoint
    get '/health' do
      content_type :json
      { status: 'ok', timestamp: Time.now.iso8601 }.to_json
    end

    # Update certificate expiry days metric
    def self.update_expire_days(domain, days, source: 'remote')
      @@cert_expire_days.set(days, labels: { domain: domain, source: source })
    end

    # Update certificate status metric
    def self.update_cert_status(domain, status, source: 'remote')
      @@cert_status.set(status ? 1 : 0, labels: { domain: domain, source: source })
    end

    # Update certificate type metric
    def self.update_cert_type(domain, is_wildcard, source: 'remote')
      @@cert_type.set(is_wildcard ? 1 : 0, labels: { domain: domain, source: source })
    end

    # Update certificate SAN count metric
    def self.update_san_count(domain, count, source: 'remote')
      @@cert_san_count.set(count, labels: { domain: domain, source: source })
    end
  end
end
