const { login } = require('../src/auth');
test('login', () => expect(login('admin', 'hunter2')).toBe(true));
