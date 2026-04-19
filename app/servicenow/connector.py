"""
ServiceNow REST API connector.
Handles ticket ingestion and response posting.
"""
import httpx
from typing import Optional
from loguru import logger
from config.settings import (
    SERVICENOW_INSTANCE,
    SERVICENOW_USERNAME,
    SERVICENOW_PASSWORD,
    SERVICENOW_CLIENT_ID,
    SERVICENOW_CLIENT_SECRET,
)


class ServiceNowConnector:
    """Connector for ServiceNow REST API (Table API + OAuth)."""

    def __init__(self):
        self.instance = SERVICENOW_INSTANCE.rstrip("/")
        self.username = SERVICENOW_USERNAME
        self.password = SERVICENOW_PASSWORD
        self.client_id = SERVICENOW_CLIENT_ID
        self.client_secret = SERVICENOW_CLIENT_SECRET
        self.access_token: Optional[str] = None
        self.client = httpx.AsyncClient(timeout=30.0)

    @property
    def is_configured(self) -> bool:
        return bool(self.instance and self.username and self.password)

    async def authenticate(self) -> bool:
        """Authenticate via OAuth2 or fall back to basic auth."""
        if not self.is_configured:
            logger.warning("ServiceNow not configured - running in standalone mode")
            return False

        if self.client_id and self.client_secret:
            return await self._oauth_auth()
        return True  # Will use basic auth

    async def _oauth_auth(self) -> bool:
        """Get OAuth2 access token."""
        try:
            resp = await self.client.post(
                f"{self.instance}/oauth_token.do",
                data={
                    "grant_type": "password",
                    "client_id": self.client_id,
                    "client_secret": self.client_secret,
                    "username": self.username,
                    "password": self.password,
                }
            )
            if resp.status_code == 200:
                self.access_token = resp.json().get("access_token")
                logger.info("ServiceNow OAuth authentication successful")
                return True
            logger.error(f"ServiceNow OAuth failed: {resp.status_code}")
            return False
        except Exception as e:
            logger.error(f"ServiceNow auth error: {e}")
            return False

    def _headers(self) -> dict:
        """Build request headers."""
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"
        return headers

    def _auth(self) -> Optional[tuple]:
        """Basic auth tuple if no OAuth token."""
        if not self.access_token and self.username and self.password:
            return (self.username, self.password)
        return None

    async def get_ticket(self, sys_id: str) -> Optional[dict]:
        """Fetch a single incident by sys_id."""
        if not self.is_configured:
            return None
        try:
            resp = await self.client.get(
                f"{self.instance}/api/now/table/incident/{sys_id}",
                headers=self._headers(),
                auth=self._auth(),
            )
            if resp.status_code == 200:
                return resp.json().get("result")
            logger.error(f"Failed to get ticket {sys_id}: {resp.status_code}")
            return None
        except Exception as e:
            logger.error(f"Error fetching ticket: {e}")
            return None

    async def get_open_tickets(self, limit: int = 20) -> list:
        """Fetch open/new incidents assigned to the AI agent."""
        if not self.is_configured:
            return []
        try:
            resp = await self.client.get(
                f"{self.instance}/api/now/table/incident",
                params={
                    "sysparm_query": "state=1^ORstate=2^ORDERBYDESCsys_created_on",
                    "sysparm_limit": limit,
                    "sysparm_display_value": "true",
                },
                headers=self._headers(),
                auth=self._auth(),
            )
            if resp.status_code == 200:
                return resp.json().get("result", [])
            return []
        except Exception as e:
            logger.error(f"Error fetching tickets: {e}")
            return []

    async def add_comment(self, sys_id: str, comment: str) -> bool:
        """Add a work note/comment to a ticket."""
        if not self.is_configured:
            return False
        try:
            resp = await self.client.patch(
                f"{self.instance}/api/now/table/incident/{sys_id}",
                headers=self._headers(),
                auth=self._auth(),
                json={"comments": comment},
            )
            return resp.status_code == 200
        except Exception as e:
            logger.error(f"Error adding comment: {e}")
            return False

    async def update_ticket(self, sys_id: str, data: dict) -> bool:
        """Update ticket fields (state, assignment, etc.)."""
        if not self.is_configured:
            return False
        try:
            resp = await self.client.patch(
                f"{self.instance}/api/now/table/incident/{sys_id}",
                headers=self._headers(),
                auth=self._auth(),
                json=data,
            )
            return resp.status_code == 200
        except Exception as e:
            logger.error(f"Error updating ticket: {e}")
            return False

    async def get_attachments(self, table: str, sys_id: str) -> list:
        """Get attachments for a record."""
        if not self.is_configured:
            return []
        try:
            resp = await self.client.get(
                f"{self.instance}/api/now/attachment",
                params={
                    "sysparm_query": f"table_name={table}^table_sys_id={sys_id}",
                },
                headers=self._headers(),
                auth=self._auth(),
            )
            if resp.status_code == 200:
                return resp.json().get("result", [])
            return []
        except Exception as e:
            logger.error(f"Error fetching attachments: {e}")
            return []

    async def download_attachment(self, attachment_sys_id: str) -> Optional[bytes]:
        """Download an attachment by sys_id."""
        if not self.is_configured:
            return None
        try:
            resp = await self.client.get(
                f"{self.instance}/api/now/attachment/{attachment_sys_id}/file",
                headers=self._headers(),
                auth=self._auth(),
            )
            if resp.status_code == 200:
                return resp.content
            return None
        except Exception as e:
            logger.error(f"Error downloading attachment: {e}")
            return None

    async def close(self):
        await self.client.aclose()


# Singleton
snow_connector = ServiceNowConnector()
