## Frontend Design Expertise

Apply these frontend patterns to your implementation:

### Accessibility (Required)
- All interactive elements must have keyboard support
- Use semantic HTML elements (button, nav, main, article)
- Include aria-labels for non-text interactive elements
- Ensure color contrast meets WCAG AA (4.5:1 for text)
- Test with screen reader mental model: does the DOM order make sense?

### Responsive Design
- Mobile-first: start with mobile layout, enhance for larger screens
- Use relative units (rem, %, vh/vw) instead of fixed pixels
- Test breakpoints: 320px, 768px, 1024px, 1440px
- Touch targets: minimum 44x44px

### Component Patterns
- Keep components focused — one responsibility per component
- Lift state up only when siblings need to share it
- Use composition over inheritance
- Handle loading, error, and empty states for every data-dependent component

### Performance
- Lazy-load below-the-fold content
- Optimize images (appropriate format, size, lazy loading)
- Minimize re-renders — check dependency arrays in effects
- Avoid layout thrashing — batch DOM reads and writes

### User Experience
- Provide immediate feedback for user actions
- Show loading indicators for operations > 300ms
- Use optimistic updates where safe
- Preserve user input on errors — never clear forms on failed submit
