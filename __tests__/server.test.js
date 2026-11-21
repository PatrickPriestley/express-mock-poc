const request = require('supertest');
const express = require('express');
const userRoutes = require('../routes/userRoutes');
const creditCheck = require('../routes/creditCheck');

// Create app instance similar to server.js
const app = express();
// Express logs every error that reaches its default handler unless the app's
// env is 'test' (jest.setup.js sets NODE_ENV=development for the data file).
// The invalid-JSON test below makes that log land after the test has ended,
// and Jest then exits 1 with every test passing.
app.set('env', 'test');
app.use(express.json());
app.use('/', userRoutes);
app.use('/', creditCheck);

describe('Server Integration', () => {
    test('should respond to user route', async () => {
        const response = await request(app)
            .get('/user/1')
            .expect(200);

        expect(response.body).toHaveProperty('id');
    });

    test('should respond to credit check route', async () => {
        const userData = {
            email: 'test@example.com',
            name: 'Test User'
        };

        const response = await request(app)
            .post('/credit-check')
            .send(userData)
            .expect(200);

        expect(response.body).toHaveProperty('creditScore');
        expect(response.body).toHaveProperty('riskLevel');
    });

    test('should handle invalid JSON parsing', async () => {
        const response = await request(app)
            .post('/credit-check')
            .send('invalid json')
            .set('Content-Type', 'application/json')
            .expect(400);

        // Express returns empty body on JSON parse error
        expect(response.body).toEqual({});
    });
});