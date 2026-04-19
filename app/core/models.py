"""
Database models for the knowledge base and ticket tracking.
"""
from datetime import datetime
from sqlalchemy import Column, Integer, String, Text, Float, DateTime, Boolean, ForeignKey, JSON
from sqlalchemy.orm import relationship, DeclarativeBase


class Base(DeclarativeBase):
    pass


class KnowledgeEntry(Base):
    """A troubleshooting knowledge base entry for a known error pattern."""
    __tablename__ = "knowledge_entries"

    id = Column(Integer, primary_key=True, autoincrement=True)
    category = Column(String(100), nullable=False, index=True)  # e.g. BSOD, Service, Network, Hardware
    subcategory = Column(String(100), nullable=True)
    error_code = Column(String(50), nullable=True, index=True)  # e.g. 0x0000007E, Event ID 41
    error_pattern = Column(Text, nullable=False)  # regex or keyword pattern to match
    title = Column(String(255), nullable=False)
    description = Column(Text, nullable=False)
    symptoms = Column(Text, nullable=False)  # What the user sees
    root_cause = Column(Text, nullable=False)
    remediation_steps = Column(Text, nullable=False)  # Human-readable steps
    remediation_script = Column(String(255), nullable=True)  # Script filename if auto-fixable
    severity = Column(String(20), default="medium")  # low, medium, high, critical
    confidence = Column(Float, default=0.8)  # How confident we are in this fix
    tags = Column(Text, nullable=True)  # Comma-separated tags for search
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    times_matched = Column(Integer, default=0)
    times_resolved = Column(Integer, default=0)


class Ticket(Base):
    """Tracks tickets processed by the agent."""
    __tablename__ = "tickets"

    id = Column(Integer, primary_key=True, autoincrement=True)
    servicenow_id = Column(String(50), nullable=True, unique=True, index=True)
    subject = Column(String(500), nullable=False)
    description = Column(Text, nullable=False)
    raw_logs = Column(Text, nullable=True)
    sanitized_input = Column(Text, nullable=True)
    status = Column(String(30), default="open")  # open, analyzing, resolved, escalated
    priority = Column(String(20), default="medium")
    assigned_to = Column(String(100), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    resolved_at = Column(DateTime, nullable=True)
    escalated = Column(Boolean, default=False)
    escalation_reason = Column(Text, nullable=True)

    responses = relationship("TicketResponse", back_populates="ticket", cascade="all, delete-orphan")


class TicketResponse(Base):
    """Agent responses to a ticket."""
    __tablename__ = "ticket_responses"

    id = Column(Integer, primary_key=True, autoincrement=True)
    ticket_id = Column(Integer, ForeignKey("tickets.id"), nullable=False)
    response_type = Column(String(30), nullable=False)  # diagnosis, fix, clarification, escalation
    content = Column(Text, nullable=False)
    matched_kb_ids = Column(Text, nullable=True)  # Comma-separated KB entry IDs
    confidence = Column(Float, default=0.0)
    remediation_script = Column(String(255), nullable=True)
    script_executed = Column(Boolean, default=False)
    script_result = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    ticket = relationship("Ticket", back_populates="responses")
