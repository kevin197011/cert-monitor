# frozen_string_literal: true

require 'time'
require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

task default: %w[push]

task :install do
  system 'gem uninstall cert-monitor -aIx'
  system 'gem build cert-monitor.gemspec'
  system 'gem install cert-monitor-0.1.0.gem'
end

task :push do
  system 'rubocop -A'
  system 'git add .'
  system "git commit -m 'Update #{Time.now}.'"
  system 'git pull'
  system 'git push origin main'
end

task :run do
  system 'export COMPOSE_BAKE=true'
  system 'docker compose up --build -d'
  system 'docker compose logs -f'
end
