const request = require('supertest');
const express = require('express');
const creditCheck = require('../routes/creditCheck');

const app = express();
app.use(express.json());
app.use('/', creditCheck);

describe('Credit Check Routes', () => {
    describe('POST /credit-check', () => {
        test('should return moderate risk for regular email', async () => {
            const userData = {
                email: 'test@example.com',
                name: 'John Doe'
            };

            const response = await request(app)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('creditScore');
            expect(response.body).toHaveProperty('riskLevel', 'Moderate');
            expect(response.body).toHaveProperty('fraudFlag', false);
            expect(response.body.creditScore).toBeGreaterThanOrEqual(400);
            expect(response.body.creditScore).toBeLessThanOrEqual(650);
        });

        test('should return high risk for +highRisk email', async () => {
            const userData = {
                email: 'test+highRisk@example.com',
                name: 'Jane Doe'
            };

            const response = await request(app)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('riskLevel', 'High');
            expect(response.body).toHaveProperty('fraudFlag', true);
            expect(response.body.creditScore).toBeGreaterThanOrEqual(150);
            expect(response.body.creditScore).toBeLessThanOrEqual(400);
            expect(response.body.additionalInfo).toContain('High risk detected');
        });

        test('should return extra high risk for +extraHighRisk email', async () => {
            const userData = {
                email: 'test+extraHighRisk@example.com',
                name: 'Bad Actor'
            };

            const response = await request(app)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('riskLevel', 'Extra High');
            expect(response.body).toHaveProperty('fraudFlag', true);
            expect(response.body.creditScore).toBeGreaterThanOrEqual(1);
            expect(response.body.creditScore).toBeLessThanOrEqual(200);
            expect(response.body.additionalInfo).toContain('Extra high risk detected');
        });
/*
        test('should return low risk for +lowRisk email', async () => {
            const userData = {
                email: 'test+lowRisk@example.com',
                name: 'Good Customer'
            };

            const response = await request(app)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('riskLevel', 'Low');
            expect(response.body).toHaveProperty('fraudFlag', false);
            expect(response.body.creditScore).toBeGreaterThanOrEqual(651);
            expect(response.body.creditScore).toBeLessThanOrEqual(800);
            expect(response.body.additionalInfo).toContain('Low risk detected');
        });

        test('should handle request without email', async () => {
            const userData = {
                name: 'Anonymous User'
            };

            const response = await request(app)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('riskLevel', 'Moderate');
            expect(response.body).toHaveProperty('fraudFlag', false);
        });

        test('should handle empty request body', async () => {
            const response = await request(app)
                .post('/credit-check')
                .send({})
                .expect(200);

            expect(response.body).toHaveProperty('riskLevel', 'Moderate');
            expect(response.body).toHaveProperty('fraudFlag', false);
        });

        test('should handle null email', async () => {
            const userData = {
                email: null,
                name: 'Test User'
            };

            const response = await request(app)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('riskLevel', 'Moderate');
            expect(response.body).toHaveProperty('fraudFlag', false);
        });

        test('should handle email with multiple risk flags (extraHighRisk takes precedence)', async () => {
            const userData = {
                email: 'test+extraHighRisk+highRisk+lowRisk@example.com',
                name: 'Multiple Flags'
            };

            const response = await request(app)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('riskLevel', 'Extra High');
            expect(response.body).toHaveProperty('fraudFlag', true);
        });

        test('should include all provided user data in response', async () => {
            const userData = {
                email: 'test@example.com',
                name: 'John Doe',
                age: 30,
                customField: 'test value'
            };

            const response = await request(app)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('email', userData.email);
            expect(response.body).toHaveProperty('name', userData.name);
            expect(response.body).toHaveProperty('age', userData.age);
            expect(response.body).toHaveProperty('customField', userData.customField);
        });

        test('should test different NODE_ENV environment', async () => {
            // Save original environment
            const originalEnv = process.env.NODE_ENV;
            
            // Test with staging environment
            process.env.NODE_ENV = 'staging';
            
            // Clear require cache to reload module with new environment
            delete require.cache[require.resolve('../routes/creditCheck')];
            const stagingCreditCheck = require('../routes/creditCheck');
            
            const stagingApp = require('express')();
            stagingApp.use(require('express').json());
            stagingApp.use('/', stagingCreditCheck);

            const userData = {
                email: 'test@example.com',
                name: 'Staging Test'
            };

            const response = await request(stagingApp)
                .post('/credit-check')
                .send(userData)
                .expect(200);

            expect(response.body).toHaveProperty('creditScore');
            expect(response.body).toHaveProperty('riskLevel', 'Moderate');
            
            // Restore original environment
            process.env.NODE_ENV = originalEnv;
            
            // Clear cache again to restore original module
            delete require.cache[require.resolve('../routes/creditCheck')];
        });
    });
});
*/