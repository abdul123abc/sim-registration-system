const { createProxyMiddleware } = require('http-proxy-middleware');

module.exports = function(app) {
  const target = process.env.REACT_APP_API_URL || 'http://localhost:3001';
  app.use(
    '/api',
    createProxyMiddleware({
      target,
      changeOrigin: true,
    })
  );

  app.use(
    '/health',
    createProxyMiddleware({
      target,
      changeOrigin: true,
    })
  );
};
