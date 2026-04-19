# Deployment Guide — AI Troubleshooting Agent

## System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Windows Server 2019 | Windows Server 2019/2022 |
| CPU | 4 cores | 8 cores |
| RAM | 8 GB | 16 GB (for LLM) |
| Disk | 20 GB free | 50 GB free |
| Network | LAN access | LAN + ServiceNow access |

## Step-by-Step Deployment

### 1. Install Python

Download Python 3.11+ from https://www.python.org/downloads/

During installation:
- Check "Add Python to PATH"
- Check "Install for all users"

Verify: `python --version`

### 2. Install Ollama

Download from https://ollama.com/download

After installation, pull the model:
```powershell
ollama pull llama3.1:8b
```

This downloads ~4.7 GB. Verify: `ollama list`

Alternative models (trade-off speed vs quality):
- `llama3.1:8b` — Good balance (recommended, 8GB RAM)
- `llama3.1:70b` — Best quality (requires 48GB RAM)
- `phi3:mini` — Fastest, lower quality (4GB RAM)
- `mistral:7b` — Good alternative (8GB RAM)

### 3. Deploy the Agent

```powershell
# Extract project files to C:\TroubleshootAgent
# Or run the automated setup:
.\setup.ps1
```

### 4. Configure

```powershell
copy .env.example .env
notepad .env
```

Fill in your ServiceNow credentials. Leave blank for standalone mode.

### 5. Start

```powershell
cd C:\TroubleshootAgent
python main.py
```

### 6. Verify

Open browser: http://localhost:8000/docs

Try the health check: http://localhost:8000/api/v1/health

### 7. Install as Service (Optional)

For auto-start on boot:
```powershell
python install_service.py install
python install_service.py start
```

## Firewall Configuration

If other machines need to access the agent, allow inbound TCP on port 8000:
```powershell
New-NetFirewallRule -DisplayName "TroubleshootAgent" -Direction Inbound -LocalPort 8000 -Protocol TCP -Action Allow
```

## ServiceNow Integration Setup

### Create an API User in ServiceNow
1. Navigate to User Administration > Users
2. Create a new user (e.g., "ai_agent")
3. Assign roles: `itil`, `rest_service`
4. Set a strong password

### Create a Business Rule
1. Navigate to System Definition > Business Rules
2. Create new:
   - Name: AI Agent Ticket Handler
   - Table: incident
   - When: after insert
   - Active: true
3. In the Advanced tab, add the script from the README

### Configure the Webhook URL
Use the internal IP of the agent server:
```
http://192.168.x.x:8000/api/v1/servicenow/webhook
```

## Monitoring

### Logs
Application logs are in `C:\TroubleshootAgent\logs\`. They rotate at 10 MB and retain for 30 days.

### Health Endpoint
Monitor `GET /api/v1/health` — returns status of Ollama and ServiceNow connections.

### Ticket Statistics
`GET /api/v1/tickets?status=escalated` — monitor escalated tickets that need human attention.

## Troubleshooting the Agent

| Issue | Solution |
|-------|----------|
| Ollama not responding | Run `ollama serve` manually, check port 11434 |
| Slow responses | Reduce model size (use phi3:mini) or add more RAM |
| ServiceNow 401 | Check credentials in .env, verify API user roles |
| Port 8000 in use | Change API_PORT in .env |
| Scripts not executing | Ensure PowerShell execution policy allows scripts |

## Security Considerations

1. **Network**: Run the agent on internal network only. Do not expose port 8000 to the internet.
2. **Authentication**: Consider adding API key authentication for production (add middleware in main.py).
3. **Sanitization**: The agent strips PII before LLM processing, but review the patterns in config/settings.py for your specific data.
4. **Scripts**: Review all remediation scripts before enabling AUTO_REMEDIATE.
5. **ServiceNow**: Use a dedicated API user with minimal required roles.
