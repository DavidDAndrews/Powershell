const http = require('http');
const https = require('https');
const url = require('url');

// Configuration
const PROXY_PORT = 3000;
const VEEAM_SERVER = '192.168.111.7';
const VEEAM_PORT = 9419;

// Create proxy server
const server = http.createServer((req, res) => {
    // Enable CORS for all requests
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-api-version');
    res.setHeader('Access-Control-Max-Age', '86400'); // 24 hours

    // Handle preflight requests
    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }

    console.log(`Proxying: ${req.method} ${req.url}`);

    // Parse the request URL
    const parsedUrl = url.parse(req.url);
    
    // Build target URL
    const targetUrl = `https://${VEEAM_SERVER}:${VEEAM_PORT}${parsedUrl.path}`;
    
    console.log(`Target: ${targetUrl}`);

    // Prepare request options
    const options = {
        hostname: VEEAM_SERVER,
        port: VEEAM_PORT,
        path: parsedUrl.path,
        method: req.method,
        headers: { ...req.headers },
        rejectUnauthorized: false // Accept self-signed certificates
    };

    // Remove host header to avoid conflicts
    delete options.headers.host;
    delete options.headers.origin;

    // Create the proxy request
    const proxyReq = https.request(options, (proxyRes) => {
        // Copy status code
        res.statusCode = proxyRes.statusCode;
        
        // Copy headers (except CORS headers we're overriding)
        Object.keys(proxyRes.headers).forEach(key => {
            if (!key.toLowerCase().startsWith('access-control-')) {
                res.setHeader(key, proxyRes.headers[key]);
            }
        });

        // Pipe response data
        proxyRes.pipe(res);
    });

    // Handle proxy request errors
    proxyReq.on('error', (error) => {
        console.error('Proxy error:', error.message);
        res.statusCode = 500;
        res.end(`Proxy Error: ${error.message}`);
    });

    // Pipe request data
    req.pipe(proxyReq);
});

// Handle server errors
server.on('error', (error) => {
    console.error('Server error:', error);
});

// Start the server
server.listen(PROXY_PORT, () => {
    console.log(`\n🚀 CORS Proxy Server running on http://localhost:${PROXY_PORT}`);
    console.log(`📡 Forwarding requests to https://${VEEAM_SERVER}:${VEEAM_PORT}`);
    console.log(`\n💡 Update your connection form to use:`);
    console.log(`   Server Address: localhost`);
    console.log(`   Port: ${PROXY_PORT}`);
    console.log(`   Protocol: HTTP (proxy handles HTTPS to Veeam)`);
    console.log(`\n🛑 Press Ctrl+C to stop`);
}); 