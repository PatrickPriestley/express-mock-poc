# Express Mock POC

This is a proof of concept (POC) project for a mock server using Express.js. The server provides endpoints for user data and credit check simulations.

## Project Structure

- `data/`: Contains JSON files for user data and credit check responses.
- `routes/`: Contains route handlers for user and credit check endpoints.
- `server.js`: The main entry point of the application.

## Installation

1. Clone the repository.
2. Run `npm install` to install the dependencies.

## Running the Server

You can start the server using the following npm scripts:

- `npm start`: Starts the server in the default environment.
- `npm run start:dev`: Starts the server in the development environment.
- `npm run start:staging`: Starts the server in the staging environment.
- `npm run start:prod`: Starts the server in the production environment.

## API Endpoints

- `GET /user/:userId`: Fetches the data for a user with the given ID.
- `POST /credit-check`: Simulates a credit check for the user data provided in the request body.

## Testing

To test the server, you can use any HTTP client like curl or Postman. Here are some example requests:

- Fetch user data: `curl http://localhost:3000/user/1`
- Perform a credit check: `curl -X POST -H "Content-Type: application/json" -d '{"email": "johndoe@example.com"}' http://localhost:3000/credit-check`
- Appending +highRisk or +lowRisk to the credit check POST body email like this `{"email": "johndoe+highRisk@example.com"}` will return low or high risk data (Credit score, risk index, etc.)