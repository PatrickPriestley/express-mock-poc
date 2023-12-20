require('dotenv').config();

const express = require('express');
const userRoutes = require('./routes/userRoutes');
const creditCheck = require('./routes/creditCheck');
const app = express();

app.use(express.json());
app.use('/', userRoutes);
app.use('/', creditCheck);

const port = process.env.PORT || 3000;
app.listen(port, () => {
    console.log(`Server running on port ${port}`);
});
