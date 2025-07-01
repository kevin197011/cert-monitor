FROM ruby:3.2-alpine

WORKDIR /app

# 安装构建依赖
RUN apk add --no-cache build-base

# 复制Gemfile和gemspec
COPY cert-monitor.gemspec .
COPY lib/cert_monitor/version.rb lib/cert_monitor/version.rb

# 安装依赖
RUN bundle install

# 复制应用代码
COPY . .

# 设置可执行权限
RUN chmod +x bin/cert-monitor

# 暴露端口
EXPOSE 9393

# 启动应用
CMD ["bin/cert-monitor"]