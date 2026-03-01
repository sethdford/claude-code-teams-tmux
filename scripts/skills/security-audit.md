## Security Audit Expertise

Apply OWASP Top 10 and security best practices:

### Injection Prevention
- Use parameterized queries for ALL database access
- Sanitize user input before rendering in HTML/templates
- Validate and sanitize file paths — prevent directory traversal
- Never execute user-supplied strings as code or commands

### Authentication
- Hash passwords with bcrypt/argon2 (never MD5/SHA1)
- Implement account lockout after failed attempts
- Use secure session management (HttpOnly, Secure, SameSite cookies)
- Require re-authentication for sensitive operations

### Authorization
- Check permissions server-side on EVERY request
- Use deny-by-default — explicitly grant access
- Verify resource ownership (user can only access their own data)
- Log authorization failures for monitoring

### Data Protection
- Never log sensitive data (passwords, tokens, PII)
- Encrypt sensitive data at rest
- Use HTTPS for all communications
- Set appropriate CORS headers — never use wildcard in production

### Secrets Management
- Never hardcode secrets in source code
- Use environment variables or secret managers
- Rotate secrets regularly
- Check for accidentally committed secrets (API keys, passwords, tokens)

### Dependency Security
- Check for known vulnerabilities in dependencies
- Pin dependency versions to prevent supply chain attacks
- Review new dependencies before adding them
