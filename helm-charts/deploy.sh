#!/usr/bin/env bash
set -e

helm upgrade --install cert-monitor . -n monitoring --create-namespace