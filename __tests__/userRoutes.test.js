const request = require('supertest');
const express = require('express');
const userRoutes = require('../routes/userRoutes');

const app = express();
app.use(express.json());
app.use('/', userRoutes);

describe('User Routes', () => {
    describe('GET /user/:userId', () => {
        test('should return user data for valid user ID', async () => {
            const response = await request(app)
                .get('/user/1')
                .expect(200);

            expect(response.body).toHaveProperty('id', 1);
            expect(response.body).toHaveProperty('firstName');
            expect(response.body).toHaveProperty('lastName');
            expect(response.body).toHaveProperty('email');
        });

        test('should return 404 for non-existent user ID', async () => {
            const response = await request(app)
                .get('/user/999')
                .expect(404);

            expect(response.body).toHaveProperty('error', 'User not found');
        });

        test('should handle invalid user ID format', async () => {
            const response = await request(app)
                .get('/user/invalid')
                .expect(404);

            expect(response.body).toHaveProperty('error', 'User not found');
        });

        test('should handle negative user ID', async () => {
            const response = await request(app)
                .get('/user/-1')
                .expect(404);

            expect(response.body).toHaveProperty('error', 'User not found');
        });

        test('should handle zero user ID', async () => {
            const response = await request(app)
                .get('/user/0')
                .expect(404);

            expect(response.body).toHaveProperty('error', 'User not found');
        });

        test('should handle float user ID (parsed as integer)', async () => {
            // Note: parseInt(1.5) = 1, so this will return user 1
            const response = await request(app)
                .get('/user/1.5')
                .expect(200);

            expect(response.body).toHaveProperty('id', 1);
        });

        test('should handle very large user ID', async () => {
            const response = await request(app)
                .get('/user/999999999')
                .expect(404);

            expect(response.body).toHaveProperty('error', 'User not found');
        });

        test('should return second user data for valid user ID 2', async () => {
            const response = await request(app)
                .get('/user/2')
                .expect(200);

            expect(response.body).toHaveProperty('id', 2);
            expect(response.body).toHaveProperty('firstName');
            expect(response.body).toHaveProperty('lastName');
            expect(response.body).toHaveProperty('email');
        });
    });
});