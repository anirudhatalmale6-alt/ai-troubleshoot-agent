"""
FastAPI routes for the troubleshooting agent API.
"""
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_session
from app.core.agent import agent
from app.core.llm import llm
from app.core.models import Ticket, TicketResponse, KnowledgeEntry
from app.knowledge_base.manager import kb_manager
from app.servicenow.connector import snow_connector

router = APIRouter()


# ─── Request/Response Models ───

class TicketRequest(BaseModel):
    subject: str = Field(..., min_length=1, max_length=500, description="Ticket subject/title")
    description: str = Field(..., min_length=1, description="Detailed description of the issue")
    logs: Optional[str] = Field(None, description="Event viewer logs, error logs, or diagnostic output")
    screenshot_text: Optional[str] = Field(None, description="OCR text extracted from screenshots")
    servicenow_id: Optional[str] = Field(None, description="ServiceNow incident sys_id")
    priority: Optional[str] = Field("medium", description="Ticket priority: low, medium, high, critical")

class TicketResponse_(BaseModel):
    ticket_id: int
    status: str
    diagnosis: str
    confidence: float
    fixes: list
    missing_info: list
    escalated: bool
    escalation_reason: Optional[str]
    matched_kb_entries: list
    response: dict

class KBSearchRequest(BaseModel):
    query: str = Field(..., min_length=1)
    category: Optional[str] = None
    limit: int = Field(5, ge=1, le=20)

class FeedbackRequest(BaseModel):
    ticket_id: int
    resolved: bool
    kb_entry_id: Optional[int] = None
    feedback: Optional[str] = None

class ServiceNowWebhookPayload(BaseModel):
    sys_id: str
    number: str
    short_description: str
    description: Optional[str] = ""
    priority: Optional[str] = "3"
    comments: Optional[str] = ""


# ─── Endpoints ───

@router.post("/api/v1/tickets/analyze", response_model=TicketResponse_)
async def analyze_ticket(request: TicketRequest, session: AsyncSession = Depends(get_session)):
    """Submit a ticket for AI analysis. Returns diagnosis and ranked fixes."""
    result = await agent.process_ticket(
        session=session,
        subject=request.subject,
        description=request.description,
        logs=request.logs,
        screenshot_text=request.screenshot_text,
        servicenow_id=request.servicenow_id,
    )
    return result


@router.get("/api/v1/tickets/{ticket_id}")
async def get_ticket(ticket_id: int, session: AsyncSession = Depends(get_session)):
    """Get ticket details and all responses."""
    result = await session.execute(select(Ticket).where(Ticket.id == ticket_id))
    ticket = result.scalar_one_or_none()
    if not ticket:
        raise HTTPException(status_code=404, detail="Ticket not found")

    responses = await session.execute(
        select(TicketResponse).where(TicketResponse.ticket_id == ticket_id)
    )
    return {
        "ticket": {
            "id": ticket.id,
            "servicenow_id": ticket.servicenow_id,
            "subject": ticket.subject,
            "description": ticket.description,
            "status": ticket.status,
            "priority": ticket.priority,
            "escalated": ticket.escalated,
            "escalation_reason": ticket.escalation_reason,
            "created_at": ticket.created_at.isoformat() if ticket.created_at else None,
            "resolved_at": ticket.resolved_at.isoformat() if ticket.resolved_at else None,
        },
        "responses": [
            {
                "id": r.id,
                "type": r.response_type,
                "content": r.content,
                "confidence": r.confidence,
                "script_executed": r.script_executed,
                "script_result": r.script_result,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in responses.scalars().all()
        ],
    }


@router.get("/api/v1/tickets")
async def list_tickets(
    status: Optional[str] = None,
    limit: int = 50,
    session: AsyncSession = Depends(get_session),
):
    """List all processed tickets."""
    query = select(Ticket).order_by(Ticket.created_at.desc()).limit(limit)
    if status:
        query = query.where(Ticket.status == status)
    result = await session.execute(query)
    tickets = result.scalars().all()
    return [
        {
            "id": t.id,
            "servicenow_id": t.servicenow_id,
            "subject": t.subject,
            "status": t.status,
            "priority": t.priority,
            "escalated": t.escalated,
            "created_at": t.created_at.isoformat() if t.created_at else None,
        }
        for t in tickets
    ]


@router.post("/api/v1/kb/search")
async def search_kb(request: KBSearchRequest, session: AsyncSession = Depends(get_session)):
    """Search the knowledge base for matching error patterns."""
    results = await kb_manager.search(session, request.query, request.category, request.limit)
    return [
        {
            "id": e.id,
            "category": e.category,
            "error_code": e.error_code,
            "title": e.title,
            "description": e.description,
            "symptoms": e.symptoms,
            "remediation_steps": e.remediation_steps,
            "remediation_script": e.remediation_script,
            "severity": e.severity,
            "confidence": e.confidence,
        }
        for e in results
    ]


@router.get("/api/v1/kb/stats")
async def kb_stats(session: AsyncSession = Depends(get_session)):
    """Get knowledge base statistics."""
    return await kb_manager.get_stats(session)


@router.post("/api/v1/feedback")
async def submit_feedback(request: FeedbackRequest, session: AsyncSession = Depends(get_session)):
    """Submit feedback on whether a diagnosis resolved the issue."""
    result = await session.execute(select(Ticket).where(Ticket.id == request.ticket_id))
    ticket = result.scalar_one_or_none()
    if not ticket:
        raise HTTPException(status_code=404, detail="Ticket not found")

    if request.resolved:
        ticket.status = "resolved"
        ticket.resolved_at = __import__("datetime").datetime.utcnow()
        if request.kb_entry_id:
            await kb_manager.increment_resolved(session, request.kb_entry_id)

    await session.commit()
    return {"status": "ok", "ticket_status": ticket.status}


@router.post("/api/v1/servicenow/webhook")
async def servicenow_webhook(
    payload: ServiceNowWebhookPayload,
    session: AsyncSession = Depends(get_session),
):
    """
    Webhook endpoint for ServiceNow to push new/updated incidents.
    Configure a ServiceNow Business Rule to POST here on incident creation.
    """
    description = payload.description or payload.short_description
    if payload.comments:
        description += f"\n\nLatest comment: {payload.comments}"

    result = await agent.process_ticket(
        session=session,
        subject=payload.short_description,
        description=description,
        servicenow_id=payload.sys_id,
    )

    # Post response back to ServiceNow
    if snow_connector.is_configured and not result.get("escalated"):
        await snow_connector.add_comment(
            payload.sys_id,
            f"[AI Agent] {result['response'].get('content', 'Analysis complete')}"
        )

    return result


@router.get("/api/v1/health")
async def health_check():
    """Service health check."""
    ollama_ok = await llm.check_health()
    snow_ok = snow_connector.is_configured
    return {
        "status": "healthy",
        "ollama": "connected" if ollama_ok else "not available (will use KB-only mode)",
        "servicenow": "configured" if snow_ok else "not configured (standalone mode)",
    }


@router.post("/api/v1/scripts/{script_name}/execute")
async def execute_script(script_name: str):
    """Manually trigger a remediation script (requires explicit opt-in)."""
    from config.settings import SCRIPTS_DIR
    script_path = SCRIPTS_DIR / script_name
    if not script_path.exists():
        raise HTTPException(status_code=404, detail=f"Script not found: {script_name}")

    # Safety check
    if not script_name.endswith(".ps1"):
        raise HTTPException(status_code=400, detail="Only .ps1 scripts allowed")

    result = agent._execute_script(script_name)
    return {"script": script_name, "result": result}
