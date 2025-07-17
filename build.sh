#!/usr/bin/env bash
set -e

release='v1'

docker build -t cert-monitor:${release} .
docker tag cert-monitor:${release} harbor.devops.io/devops/cert-monitor:${release}
docker push harbor.devops.io/devops/cert-monitor:${release}