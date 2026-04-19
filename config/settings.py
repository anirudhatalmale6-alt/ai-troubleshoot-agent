"""
Application configuration settings.
"""
import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()

# Base paths
BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
SCRIPTS_DIR = BASE_DIR / "app" / "scripts" / "remediation"
LOGS_DIR = BASE_DIR / "logs"

# Ensure directories exist
DATA_DIR.mkdir(exist_ok=True)
LOGS_DIR.mkdir(exist_ok=True)

# Database
DATABASE_URL = f"sqlite+aiosqlite:///{DATA_DIR / 'knowledge_base.db'}"

# Ollama (local LLM)
OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.1:8b")

# ServiceNow
SERVICENOW_INSTANCE = os.getenv("SERVICENOW_INSTANCE", "")  # e.g. https://yourcompany.service-now.com
SERVICENOW_USERNAME = os.getenv("SERVICENOW_USERNAME", "")
SERVICENOW_PASSWORD = os.getenv("SERVICENOW_PASSWORD", "")
SERVICENOW_CLIENT_ID = os.getenv("SERVICENOW_CLIENT_ID", "")
SERVICENOW_CLIENT_SECRET = os.getenv("SERVICENOW_CLIENT_SECRET", "")

# Data sanitization
SANITIZE_PATTERNS = [
    r'\b\d{3}-\d{2}-\d{4}\b',          # SSN
    r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b',  # Email
    r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b',  # IP addresses
    r'\b(?:\d{4}[-\s]?){3}\d{4}\b',     # Credit card numbers
    r'(?i)password\s*[=:]\s*\S+',        # Passwords in config
    r'(?i)api[_-]?key\s*[=:]\s*\S+',    # API keys
    r'(?i)secret\s*[=:]\s*\S+',          # Secrets
    r'(?i)token\s*[=:]\s*\S+',           # Tokens
]

# Agent settings
MAX_RETRIES = 3
ESCALATION_CONFIDENCE_THRESHOLD = 0.4  # Below this, escalate to human
AUTO_REMEDIATE = False  # Set True to auto-run scripts (requires explicit opt-in)

# API settings
API_HOST = os.getenv("API_HOST", "0.0.0.0")
API_PORT = int(os.getenv("API_PORT", "8000"))
