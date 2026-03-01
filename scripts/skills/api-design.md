## API Design Expertise

Apply these API design patterns:

### RESTful Conventions
- Use nouns for resources, HTTP verbs for actions (GET /users, POST /users, DELETE /users/:id)
- Return appropriate status codes: 200 OK, 201 Created, 400 Bad Request, 404 Not Found, 422 Unprocessable
- Use consistent error response format: `{ "error": { "code": "...", "message": "..." } }`
- Version APIs when breaking changes are needed (/v1/users, /v2/users)

### Request/Response Design
- Accept and return JSON (Content-Type: application/json)
- Use camelCase for JSON field names
- Include pagination for list endpoints (limit, offset or cursor)
- Support filtering and sorting via query parameters

### Input Validation
- Validate ALL input at the API boundary — never trust client data
- Return specific validation errors with field names
- Sanitize strings against injection (SQL, XSS, command injection)
- Set reasonable size limits on request bodies

### Error Handling
- Never expose stack traces or internal errors to clients
- Log full error details server-side
- Use consistent error codes that clients can programmatically handle
- Include request-id in responses for debugging

### Authentication & Authorization
- Verify auth on EVERY endpoint (don't rely on frontend-only checks)
- Use principle of least privilege for authorization
- Validate tokens/sessions on each request
- Rate limit sensitive endpoints (login, password reset)
