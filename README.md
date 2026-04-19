# AI Troubleshooting Agent

An intelligent, self-contained AI agent for technical troubleshooting of Windows environments. Designed for internal IT teams, it integrates with ServiceNow, analyzes logs and event viewer data, and provides ranked remediation steps with optional automated script execution.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    AI Troubleshooting Agent                   │
├──────────────┬──────────────┬──────────────┬─────────────────┤
│  FastAPI     │  Ollama LLM  │  Knowledge   │  ServiceNow     │
│  REST API    │  (on-prem)   │  Base (55+)  │  Connector      │
├──────────────┼──────────────┼──────────────┼─────────────────┤
│  Sanitizer   │  Agent Core  │  PowerShell  │  Ticket         │
│  (PII strip) │  (orchestr.) │  Scripts(19) │  Tracker (SQL)  │
└──────────────┴──────────────┴──────────────┴─────────────────┘
```

### Components

| Component | Description |
|-----------|-------------|
| **FastAPI REST API** | HTTP endpoints for ticket submission, KB search, health checks |
| **Ollama LLM** | Local language model (llama3.1:8b) for intelligent analysis — no data leaves your network |
| **Knowledge Base** | SQLite database with 55 common Windows error patterns (BSOD, services, network, AD, Office, hardware, drivers, security, performance) |
| **Data Sanitizer** | Strips PII, credentials, IPs, and secrets before LLM processing |
| **ServiceNow Connector** | REST API integration for ticket ingestion and response posting |
| **Remediation Scripts** | 19 PowerShell scripts for common automated fixes |
| **Ticket Tracker** | SQLite-based ticket history with response tracking |

## Quick Start

### Prerequisites
- Windows Server 2019 (or Windows 10/11)
- Python 3.10+
- 8 GB RAM minimum (16 GB recommended for LLM)

### Installation

**Option 1: Automated Setup (Recommended)**
```powershell
# Run as Administrator
.\setup.ps1
```

**Option 2: Manual Setup**
```powershell
# 1. Install Python 3.11+ from python.org
# 2. Install Ollama from ollama.com
# 3. Pull the LLM model
ollama pull llama3.1:8b

# 4. Install dependencies
pip install -r requirements.txt

# 5. Configure
copy .env.example .env
# Edit .env with your settings

# 6. Run
python main.py
```

### Start the Agent
```powershell
python main.py
```
The API starts at `http://localhost:8000`. Interactive docs at `http://localhost:8000/docs`.

## API Endpoints

### Core Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/tickets/analyze` | Submit a ticket for AI analysis |
| GET | `/api/v1/tickets/{id}` | Get ticket details and responses |
| GET | `/api/v1/tickets` | List all tickets (filter by status) |
| POST | `/api/v1/kb/search` | Search the knowledge base |
| GET | `/api/v1/kb/stats` | Knowledge base statistics |
| POST | `/api/v1/feedback` | Submit resolution feedback |
| POST | `/api/v1/servicenow/webhook` | ServiceNow incident webhook |
| POST | `/api/v1/scripts/{name}/execute` | Manually run a remediation script |
| GET | `/api/v1/health` | Health check (Ollama + ServiceNow status) |

### Example: Submit a Ticket

```bash
curl -X POST http://localhost:8000/api/v1/tickets/analyze \
  -H "Content-Type: application/json" \
  -d '{
    "subject": "BSOD on user laptop",
    "description": "User reports blue screen with IRQL_NOT_LESS_OR_EQUAL after installing new USB dock. Happens 2-3 times per day.",
    "logs": "BugCheck 0x0000000A, Parameter1 0x00000000, ndis.sys"
  }'
```

**Response:**
```json
{
  "ticket_id": 1,
  "status": "diagnosed",
  "diagnosis": "IRQL_NOT_LESS_OR_EQUAL caused by ndis.sys — network driver conflict with USB dock",
  "confidence": 0.85,
  "fixes": [
    {
      "rank": 1,
      "description": "Update the network adapter driver from the dock manufacturer",
      "reason": "ndis.sys crash with USB dock suggests incompatible NIC driver",
      "script": "fix_bsod_general.ps1",
      "manual_steps": ["Download latest driver from dock manufacturer", "Uninstall current driver via Device Manager", "Install new driver and reboot"]
    }
  ],
  "escalated": false,
  "matched_kb_entries": [
    {"id": 2, "title": "BSOD: IRQL_NOT_LESS_OR_EQUAL", "category": "BSOD"}
  ]
}
```

## ServiceNow Integration

### Setup

1. Edit `.env` with your ServiceNow instance URL and credentials
2. In ServiceNow, create a Business Rule on the `incident` table:
   - When: **after insert**
   - Script:
```javascript
(function executeRule(current, previous) {
    var r = new sn_ws.RESTMessageV2();
    r.setEndpoint('http://YOUR_AGENT_IP:8000/api/v1/servicenow/webhook');
    r.setHttpMethod('POST');
    r.setRequestHeader('Content-Type', 'application/json');
    r.setRequestBody(JSON.stringify({
        sys_id: current.sys_id.toString(),
        number: current.number.toString(),
        short_description: current.short_description.toString(),
        description: current.description.toString(),
        priority: current.priority.toString()
    }));
    r.execute();
})(current, previous);
```

3. The agent will automatically analyze new incidents and post responses back as work notes.

### Escalation

When the agent cannot resolve an issue (confidence below 40%), it:
1. Marks the ticket as "escalated"
2. Posts a detailed summary of what it tried
3. Lists what additional information is needed
4. Recommends next steps for the human technician

## Knowledge Base

55 entries across 10 categories:

| Category | Count | Examples |
|----------|-------|---------|
| BSOD | 8 | IRQL_NOT_LESS_OR_EQUAL, PAGE_FAULT, DPC_WATCHDOG |
| Service | 8 | Windows Update, Print Spooler, RPC, WMI, Activation |
| Network | 7 | DHCP, VPN, Wi-Fi, SMB, Firewall, NIC |
| Disk | 5 | Low space, SMART, NTFS corruption, BitLocker, USB |
| Active Directory | 5 | Account lockout, replication, GPO, trust, DNS |
| Office | 5 | Outlook, Teams, Excel, OneDrive, activation |
| Hardware | 5 | RAM, CPU/WHEA, GPU/TDR, monitor, audio |
| Driver | 4 | Code 28, unsigned, rollback, printer |
| Security | 4 | Defender, certificates, UAC, ransomware |
| Performance | 4 | High CPU, memory leak, slow boot, 100% disk |

### Adding Custom Entries

Add entries to `app/knowledge_base/seed_data.py` following the existing format, then restart the agent. New entries are automatically added on startup.

## Remediation Scripts

19 PowerShell scripts in `app/scripts/remediation/`:

| Script | Purpose |
|--------|---------|
| fix_bsod_general.ps1 | SFC, DISM repair, memory diagnostic |
| fix_disk_check.ps1 | Chkdsk, SMART health check |
| fix_disk_cleanup.ps1 | Temp cleanup, component store |
| fix_disk_usage.ps1 | Disable SysMain, identify I/O hogs |
| fix_windows_update.ps1 | Reset WU components |
| fix_print_spooler.ps1 | Clear spooler, restart service |
| fix_network_reset.ps1 | DNS flush, Winsock reset, TCP/IP |
| fix_vpn_l2tp.ps1 | L2TP/IPsec registry fix |
| fix_wifi_power.ps1 | Disable power management |
| fix_wmi_repair.ps1 | WMI repository repair |
| fix_services_restart.ps1 | Safe service restart |
| fix_outlook_repair.ps1 | OST cache, profile repair |
| fix_office_activation.ps1 | License cache reset |
| fix_teams_cache.ps1 | Teams cache cleanup |
| fix_power_settings.ps1 | Fast startup, power diag |
| fix_performance_cpu.ps1 | Top CPU processes, service restart |
| fix_startup_optimize.ps1 | Startup program cleanup |
| fix_defender_reset.ps1 | Defender policy reset |
| fix_audio_service.ps1 | Audio service restart |

### Auto-Remediation

By default, scripts must be triggered manually. To enable auto-execution:
1. Set `AUTO_REMEDIATE=True` in `config/settings.py`
2. Restart the agent

**Warning**: Only enable auto-remediation after thorough testing in your environment.

## Data Sanitization

Before any text is sent to the LLM, the sanitizer removes:
- Social Security Numbers
- Email addresses
- IP addresses
- Credit card numbers
- Passwords, API keys, secrets, and tokens

Sensitive data never leaves your machine — the LLM runs locally via Ollama.

## Running as a Windows Service

```powershell
# Install
python install_service.py install

# Start
python install_service.py start

# Stop
python install_service.py stop

# Remove
python install_service.py remove
```

For best results, use [NSSM](https://nssm.cc/) — download `nssm.exe` and place it in the project directory before running the install script.

## Configuration

All settings in `.env` (copy from `.env.example`):

| Variable | Default | Description |
|----------|---------|-------------|
| OLLAMA_BASE_URL | http://localhost:11434 | Ollama API endpoint |
| OLLAMA_MODEL | llama3.1:8b | LLM model to use |
| SERVICENOW_INSTANCE | (empty) | Your ServiceNow URL |
| SERVICENOW_USERNAME | (empty) | ServiceNow API user |
| SERVICENOW_PASSWORD | (empty) | ServiceNow API password |
| API_HOST | 0.0.0.0 | API listen address |
| API_PORT | 8000 | API listen port |

## Project Structure

```
TroubleshootAgent/
├── main.py                          # Entry point
├── setup.ps1                        # Automated setup script
├── install_service.py               # Windows service installer
├── requirements.txt                 # Python dependencies
├── .env.example                     # Configuration template
├── config/
│   └── settings.py                  # Application settings
├── app/
│   ├── api/
│   │   └── routes.py                # REST API endpoints
│   ├── core/
│   │   ├── agent.py                 # Main troubleshooting agent
│   │   ├── database.py              # Database init and sessions
│   │   ├── llm.py                   # Ollama LLM integration
│   │   └── models.py                # SQLAlchemy models
│   ├── knowledge_base/
│   │   ├── manager.py               # KB search and management
│   │   └── seed_data.py             # 55 error pattern entries
│   ├── sanitization/
│   │   └── sanitizer.py             # PII/credential stripping
│   ├── servicenow/
│   │   └── connector.py             # ServiceNow REST API client
│   └── scripts/
│       └── remediation/             # 19 PowerShell fix scripts
├── data/                            # SQLite databases (auto-created)
├── logs/                            # Application logs (auto-created)
└── docs/
    └── DEPLOYMENT_GUIDE.md          # Detailed deployment guide
```
