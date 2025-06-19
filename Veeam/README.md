# Veeam Enterprise Reporter - Python Edition

A modern, web-based dashboard for monitoring Veeam Backup & Replication jobs, built with Python Flask. This application provides a clean interface to view job statuses, detailed history, and backup file paths through the Veeam REST API.

![Python Edition](https://img.shields.io/badge/Python-3.8+-blue.svg)
![Flask](https://img.shields.io/badge/Flask-2.3+-green.svg)
![macOS](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)

## Features

✅ **Modern Web Interface** - Clean, responsive design optimized for Mac  
✅ **Real-time Job Monitoring** - Live status updates for all backup jobs  
✅ **Detailed Job History** - View successful runs with backup file paths  
✅ **Advanced Filtering** - Search and filter jobs by type, status, name  
✅ **Export Functionality** - Export job data to CSV  
✅ **No CORS Issues** - Server-side API calls eliminate browser restrictions  
✅ **Secure Credentials** - Optional encrypted credential storage  
✅ **Responsive Design** - Works on desktop, tablet, and mobile  

## Screenshots

### Dashboard Overview
The main dashboard shows job summary cards and a detailed table of all backup jobs.

### Job Details Modal
Click "Details" on any job to see comprehensive information including successful run history with file paths.

## Requirements

- **Python 3.8+**
- **macOS 10.14+** (tested on macOS Sequoia)
- **Veeam Backup & Replication** server with REST API enabled
- **Network access** to Veeam server

## Installation

### 1. Clone or Download

```bash
# Download the files to your desired directory
cd ~/Downloads
# Ensure you have all files: app.py, requirements.txt, templates/, static/
```

### 2. Set Up Python Environment

```bash
# Create a virtual environment (recommended)
python3 -m venv veeam-reporter-env

# Activate the virtual environment
source veeam-reporter-env/bin/activate

# Install dependencies
pip install -r requirements.txt
```

### 3. Run the Application

```bash
# Start the Flask server
python app.py
```

The application will start on `http://127.0.0.1:5000`

### 4. Access the Interface

Open your web browser and navigate to:
```
http://localhost:5000
```

## Usage

### Connecting to Veeam Server

1. **Enter Connection Details:**
   - Server Address: Your Veeam B&R server IP/hostname
   - Port: Usually 9419 (default)
   - Username: Veeam account username
   - Password: Veeam account password

2. **Optional:** Check "Remember credentials securely" to save connection details

3. **Click Connect** - The app will authenticate and load job data

### Dashboard Features

#### Summary Cards
- **Successful Jobs**: Jobs that completed successfully
- **Warning Jobs**: Jobs completed with warnings
- **Failed Jobs**: Jobs that failed or were cancelled
- **Running Jobs**: Currently active jobs

#### Jobs Table
- **Search**: Type to filter jobs by name
- **Type Filter**: Filter by Backup, BackupCopy, or Replica
- **Status Filter**: Filter by job status (Success, Warning, Failed, etc.)
- **Export CSV**: Download current job data as CSV file

#### Job Details
Click "Details" on any job to see:
- Complete job information (ID, type, status, repository, retention)
- **Successful Run History**: List of successful backup sessions with file paths
- Detailed scheduling information

### File Path Display

The Python edition successfully retrieves backup file paths by:
- Trying multiple Veeam API endpoints
- Handling different API versions (rev1, rev2)
- Providing fallback display options
- Clear error handling and logging

## Configuration

### Environment Variables

Set these environment variables for enhanced security:

```bash
export SECRET_KEY="your-secure-secret-key-here"
```

### SSL/TLS

The application automatically:
- Uses HTTPS for Veeam connections
- Disables SSL verification for self-signed certificates
- Suppresses SSL warnings in console

## File Structure

```
veeam-enterprise-reporter/
├── app.py                 # Main Flask application
├── requirements.txt       # Python dependencies
├── README.md             # This file
├── templates/
│   └── index.html        # Main HTML template
└── static/
    ├── styles.css        # CSS styling
    └── app.js           # Frontend JavaScript
```

## API Endpoints

The Flask application exposes these internal API endpoints:

- `POST /api/connect` - Authenticate with Veeam server
- `GET /api/jobs` - Retrieve all jobs with status information
- `GET /api/job/<id>/history` - Get detailed history for specific job
- `POST /api/disconnect` - Disconnect from Veeam server

## Troubleshooting

### Common Issues

**Connection Refused**
- Verify Veeam server address and port
- Ensure REST API is enabled on Veeam server
- Check firewall settings

**Authentication Failed**
- Verify username and password
- Ensure account has appropriate Veeam permissions
- Check if account is locked

**No File Paths Shown**
- Check console logs for API errors
- Verify resourceId values in session data
- Some backup types may not expose file paths

### Debug Mode

Run with debug logging:
```bash
export FLASK_DEBUG=1
python app.py
```

### Logs

Check Python console output for:
- API call details
- Authentication status
- Error messages
- Performance information

## Development

### Running in Development

```bash
# Enable debug mode
export FLASK_ENV=development
export FLASK_DEBUG=1

# Run with auto-reload
python app.py
```

### Code Structure

- **VeeamAPI Class**: Handles all Veeam REST API interactions
- **Flask Routes**: Web endpoints for frontend communication
- **Frontend**: Vanilla JavaScript with modern async/await
- **Styling**: Modern CSS with gradients and animations

## Security Notes

- Credentials are stored in Flask sessions (server-side)
- SSL verification is disabled for development (self-signed certs)
- Consider proper SSL setup for production use
- Environment variables recommended for sensitive data

## Performance

- API calls are made server-side (faster than browser CORS)
- Session data is cached during connection
- Optimized for macOS system fonts and styling
- Responsive design reduces mobile data usage

## Comparison with Original

| Feature | Original (HTML/JS) | Python Edition |
|---------|-------------------|----------------|
| CORS Issues | ❌ Common problem | ✅ Eliminated |
| Server-side Processing | ❌ No | ✅ Yes |
| Error Handling | ⚠️ Basic | ✅ Comprehensive |
| Credential Storage | ⚠️ Browser only | ✅ Server-side secure |
| API Flexibility | ⚠️ Limited | ✅ Multiple endpoints |
| Deployment | ⚠️ Requires web server | ✅ Standalone app |

## License

This project is provided as-is for educational and professional use.

## Contributing

Feel free to submit issues and enhancement requests!

## Support

For issues related to:
- **Veeam API**: Check Veeam documentation
- **Python/Flask**: Review Flask documentation
- **This Application**: Check console logs and error messages

---

**Built for macOS with ❤️ using Python Flask** 