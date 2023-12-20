const express = require('express');
const router = express.Router();
const fs = require('fs');
const path = require('path');

const environment = process.env.NODE_ENV || 'development'; 

const dataFileName = `creditCheck.${environment}.json`;
const templatePath = path.join(__dirname, '..', 'data', dataFileName);
const creditResponseTemplate = JSON.parse(fs.readFileSync(templatePath, 'utf8'));

router.post('/credit-check', (req, res) => {
    const userData = req.body;

    // Check if the email address contains +highRisk or +lowRisk
    const isHighRisk = userData.email && userData.email.includes('+highRisk');
    const isLowRisk = userData.email && userData.email.includes('+lowRisk');

    // Adjust the logic based on the keyword in the email address
    let creditCheckResult;
    if (isHighRisk) {
        creditCheckResult = {
            creditScore: Math.floor(Math.random() * (400 - 150 + 1)) + 150,
            riskLevel: 'High',
            fraudFlag: true
        };
    } else if (isLowRisk) {
        creditCheckResult = {
            creditScore: Math.floor(Math.random() * (800 - 651 + 1)) + 651,
            riskLevel: 'Low',
            fraudFlag: false
        };
    } else {
        creditCheckResult = {
            creditScore: Math.floor(Math.random() * (650 - 400 + 1)) + 400,
            riskLevel: 'Moderate',
            fraudFlag: false
        };
    }

    const response = {
        ...creditResponseTemplate,
        ...userData,
        ...creditCheckResult,
        additionalInfo: isHighRisk ? 'High risk detected based on email flag'
                      : isLowRisk ? 'Low risk detected based on email flag'
                      : 'Processed mock credit check'
    };

    res.json(response);
});

module.exports = router;
