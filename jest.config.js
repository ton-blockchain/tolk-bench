module.exports = {
    preset: 'ts-jest',
    testEnvironment: 'node',
    reporters: ['default', __dirname + '/tests/gas-reporter.js'],
};
