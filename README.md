# SSL Certificate Monitor

A Ruby-based online domain certificate monitoring tool that supports fetching domain lists from Nacos configuration center, automatically checking SSL certificate status, and exporting metrics in Prometheus format.

## Features

- Dynamic domain list fetching from Nacos configuration center
- Automatic SSL certificate status and expiration monitoring
- Prometheus format metrics export
- Hot configuration reload support
- Docker containerization support
- Detailed logging
- Flexible configuration options

## Quick Start

### Local Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/cert-monitor.git
cd cert-monitor
```

2. Install dependencies:
```bash
gem build cert-monitor.gemspec
gem install cert-monitor-0.1.0.gem
```

3. Configure environment variables:
```bash
cp env.template .env
# Edit .env file with your configuration
```

4. Run the service:
```bash
cert-monitor
```

### Docker Deployment

1. Build the image:
```bash
docker compose build
```

2. Start the service:
```bash
docker compose up -d
```

## Configuration

### Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| NACOS_ADDR | Nacos server address | http://localhost:8848 | Yes |
| NACOS_NAMESPACE | Nacos namespace | devops | Yes |
| NACOS_GROUP | Nacos configuration group | DEFAULT_GROUP | Yes |
| NACOS_DATA_ID | Nacos configuration ID | cert_domains | Yes |
| PORT | Service listen port | 9393 | No |
| LOG_LEVEL | Log level | info | No |
| CHECK_INTERVAL | Check interval in seconds | 60 | No |
| CONNECT_TIMEOUT | Connection timeout in seconds | 10 | No |
| EXPIRE_WARNING_DAYS | Certificate expiration warning threshold in days | 30 | No |
| NACOS_POLL_INTERVAL | Nacos configuration polling interval in seconds | 30 | No |
| MAX_CONCURRENT_CHECKS | Maximum number of concurrent domain checks | 50 | No |

### Nacos Configuration Format

```yaml
domains:
  - example.com
  - example.org
threshold_days: 30
```

## Metrics

The service provides the following Prometheus format metrics at the `/metrics` endpoint:

### cert_expire_days
- Type: Gauge
- Description: Number of days until SSL certificate expires
- Labels:
  - domain: Domain name

### cert_status
- Type: Gauge
- Description: SSL certificate check status (1=valid, 0=invalid)
- Labels:
  - domain: Domain name

## Prometheus Configuration Example

```yaml
scrape_configs:
  - job_name: 'cert-monitor'
    static_configs:
      - targets: ['localhost:9393']
    metrics_path: '/metrics'
    scrape_interval: 5m
```

## Grafana Alert Rule Example

```yaml
alert: SSLCertificateExpiringSoon
expr: cert_expire_days < 30
for: 10m
labels:
  severity: warning
annotations:
  summary: "SSL Certificate Expiring Soon"
  description: "Certificate for {{ $labels.domain }} will expire in {{ $value }} days"
```

## Development Guide

### Project Structure

```
cert-monitor/
├── bin/
│   └── cert-monitor         # Executable file
├── lib/
│   └── cert_monitor/
│       ├── version.rb       # Version definition
│       ├── config.rb        # Configuration management
│       ├── nacos_client.rb  # Nacos client
│       ├── checker.rb       # Certificate checker
│       └── exporter.rb      # Prometheus exporter
├── Dockerfile              # Docker build file
├── docker-compose.yml      # Docker compose configuration
└── cert-monitor.gemspec    # Gem configuration
```

### Local Development

1. Install development dependencies:
```bash
bundle install
```

2. Run tests:
```bash
bundle exec rspec
```

3. Local debugging:
```bash
bundle exec bin/cert-monitor
```

## Troubleshooting

### 1. Cannot Connect to Nacos Server

- Check if NACOS_ADDR configuration is correct
- Verify if Nacos server is running
- Check network connectivity and firewall settings

### 2. Certificate Check Failed

- Verify if domain is accessible
- Check if domain has SSL certificate configured
- Review detailed error logs

### 3. Metrics Not Updating

- Check CHECK_INTERVAL configuration
- Verify if Prometheus is correctly configured
- Review application logs for errors

## Contributing

1. Fork the project
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details

## Author

- Your Name - [@yourusername](https://github.com/yourusername)

## Acknowledgments

- [Nacos](https://nacos.io/) - Configuration Center
- [Prometheus](https://prometheus.io/) - Monitoring System
- [Ruby](https://www.ruby-lang.org/) - Programming Language