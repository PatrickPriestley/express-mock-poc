describe('Server Configuration', () => {
    let originalConsoleLog;
    let consoleSpy;
    let mockListen;
    let mockApp;

    beforeEach(() => {
        // Mock console.log to capture server startup message
        originalConsoleLog = console.log;
        consoleSpy = jest.fn();
        console.log = consoleSpy;
        
        // Mock the listen function
        mockListen = jest.fn((port, callback) => {
            if (callback) callback();
            return { close: jest.fn() };
        });

        // Mock Express app
        mockApp = {
            use: jest.fn(),
            listen: mockListen
        };

        // Mock express
        jest.doMock('express', () => {
            const mockExpress = jest.fn(() => mockApp);
            mockExpress.json = jest.fn();
            return mockExpress;
        });

        // Mock routes
        jest.doMock('../routes/userRoutes', () => ({}));
        jest.doMock('../routes/creditCheck', () => ({}));
        
        // Clear modules to ensure fresh require
        jest.resetModules();
        delete process.env.PORT;
    });

    afterEach(() => {
        console.log = originalConsoleLog;
        delete process.env.PORT;
        jest.clearAllMocks();
        jest.resetModules();
    });

    test('should start server with default port 3000', () => {
        require('../server');
        
        expect(consoleSpy).toHaveBeenCalledWith('Server running on port 3000');
        expect(mockListen).toHaveBeenCalledWith(3000, expect.any(Function));
    });

    test('should start server with custom PORT from environment', () => {
        process.env.PORT = '8080';
        
        require('../server');
        
        expect(consoleSpy).toHaveBeenCalledWith('Server running on port 8080');
        expect(mockListen).toHaveBeenCalledWith('8080', expect.any(Function));
    });

    test('should configure express middleware', () => {
        require('../server');
        
        expect(mockApp.use).toHaveBeenCalledTimes(3); // json middleware + 2 routes
    });
});