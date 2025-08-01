const request = require('supertest');
const express = require('express');

// Mock the server file by requiring it but not starting the server
jest.mock('../server', () => {
    const express = require('express');
    const userRoutes = require('../routes/userRoutes');
    const creditCheck = require('../routes/creditCheck');
    
    const app = express();
    app.use(express.json());
    app.use('/', userRoutes);
    app.use('/', creditCheck);
    
    return app;
});

const app = require('../server');

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
});