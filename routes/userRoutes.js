const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');

const usersFilePath = path.join('data', 'users.json');
const usersFileContent = fs.readFileSync(usersFilePath, 'utf8');
const users = JSON.parse(usersFileContent).users;

router.get('/user/:userId', (req, res) => {
    const userId = parseInt(req.params.userId);
    const user = users.find(u => u.id === userId);

    if (user) {
        res.json(user);
    } else {
        res.status(404).json({ error: 'User not found' });
    }
});

module.exports = router;
