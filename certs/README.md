# SSL Certificates Directory

This directory contains SSL certificates used by the cert-monitor project.

## Directory Structure

- `active/` - Currently active certificates
  - Organized by domain name
  - Each domain directory contains:
    - `cert.pem` - Certificate file
    - `key.pem` - Private key file
    - `chain.pem` - Certificate chain file

- `expired/` - Expired certificates archive
  - Organized by expiration date (YYYY-MM)
  - Useful for historical tracking and analysis

- `staging/` - Certificates for staging/test environments
  - Same structure as active directory

- `backup/` - Certificate backups
  - Automated backups before certificate updates

## Usage Guidelines

1. Always keep private keys secure and restrict access permissions
2. Use descriptive names for domain directories
3. Maintain proper file permissions:
   - Certificate files: 644 (-rw-r--r--)
   - Private keys: 600 (-rw-------)
   - Directories: 755 (drwxr-xr-x)

## Certificate Naming Convention

- Domain directories: Use full domain name (e.g., `example.com`)
- Certificate files: Standard names (`cert.pem`, `key.pem`, `chain.pem`)
- Expired certificates: Include expiration date in directory name

## Security Notes

- Never commit private keys to version control
- Regularly audit access permissions
- Keep backup copies in a secure location
- Monitor certificate expiration dates