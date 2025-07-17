FROM ruby:3.2-alpine

WORKDIR /app

# Install build dependencies and tzdata for timezone
RUN apk add --no-cache build-base tzdata

# Set timezone to Asia/Hong_Kong
ENV TZ=Asia/Hong_Kong
RUN cp /usr/share/zoneinfo/Asia/Hong_Kong /etc/localtime && \
    echo "Asia/Hong_Kong" > /etc/timezone

# Copy all gem files
COPY Gemfile Gemfile.lock ./
COPY cert-monitor.gemspec ./
COPY lib lib/
COPY bin bin/
COPY README.md ./
COPY certs/ssl /app/certs/ssl/

# Install dependencies and build the gem
RUN gem build cert-monitor.gemspec && \
    gem install ./cert-monitor-*.gem

# Set executable permissions
RUN chmod +x bin/cert-monitor

# Expose port
EXPOSE 9393

# Start application
CMD ["cert-monitor"]