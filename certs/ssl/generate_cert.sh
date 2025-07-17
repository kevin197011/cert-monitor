#!/bin/bash

# 生成证书的函数
generate_cert() {
    local domain=$1
    local is_wildcard=${2:-true}  # 默认生成泛域名证书
    local key_file="${domain}.key"
    local cert_file="${domain}.crt"
    local config_file="openssl.cnf"

    if [ "$is_wildcard" = "false" ]; then
        config_file="openssl.single.cnf"
        echo "Generating single domain certificate for ${domain}..."
    else
        echo "Generating wildcard certificate for ${domain} (*.${domain})..."
    fi

    local temp_config="temp_${domain}.cnf"

    # 创建临时配置文件
    sed "s/\${DOMAIN}/${domain}/g" "${config_file}" > "${temp_config}"

    # 生成私钥
    openssl genrsa -out "${key_file}" 2048

    # 生成证书
    openssl req -new -x509 -nodes -sha256 \
        -key "${key_file}" \
        -out "${cert_file}" \
        -days 3650 \
        -config "${temp_config}"

    # 删除临时配置文件
    rm "${temp_config}"

    echo "Generated ${key_file} and ${cert_file}"
    echo "Certificate details:"
    openssl x509 -in "${cert_file}" -text -noout | grep "Subject:\|DNS:"
    echo "----------------------------------------"
}

# 生成泛域名证书
generate_cert "devops.com"
generate_cert "test.com"
generate_cert "kk.com"

# 生成单域名证书
generate_cert "admin.devops.com" false