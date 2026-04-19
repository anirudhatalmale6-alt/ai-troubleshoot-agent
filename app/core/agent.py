"""
Core troubleshooting agent: orchestrates ticket analysis, KB lookup, LLM reasoning, and response.
"""
import os
import subprocess
from datetime import datetime
from typing import Optional
from sqlalchemy.ext.asyncio import AsyncSession
from loguru import logger

from app.core.models import Ticket, TicketResponse
from app.core.llm import llm
from app.knowledge_base.manager import kb_manager
from app.sanitization.sanitizer import sanitizer
from config.settings import ESCALATION_CONFIDENCE_THRESHOLD, AUTO_REMEDIATE, SCRIPTS_DIR


class TroubleshootAgent:
    """Main troubleshooting agent that processes tickets end-to-end."""

    async def process_ticket(
        self,
        session: AsyncSession,
        subject: str,
        description: str,
        logs: Optional[str] = None,
        screenshot_text: Optional[str] = None,
        servicenow_id: Optional[str] = None,
    ) -> dict:
        """
        Process a troubleshooting ticket through the full pipeline:
        1. Sanitize input
        2. Search knowledge base
        3. Send to LLM for analysis
        4. Generate response with ranked fixes
        5. Optionally trigger remediation scripts
        6. Escalate if confidence is low
        """
        # Step 1: Create ticket record
        ticket = Ticket(
            servicenow_id=servicenow_id,
            subject=subject,
            description=description,
            raw_logs=logs,
            status="analyzing",
        )
        session.add(ticket)
        await session.flush()
        logger.info(f"Processing ticket #{ticket.id}: {subject}")

        # Step 2: Sanitize input
        full_input = self._build_input(subject, description, logs, screenshot_text)
        sanitized = sanitizer.sanitize(full_input)
        ticket.sanitized_input = sanitized

        # Step 3: Search knowledge base
        kb_results = await kb_manager.search(session, sanitized, limit=5)
        kb_context = kb_manager.format_for_llm(kb_results)

        # Update match counts
        for entry in kb_results:
            await kb_manager.increment_matched(session, entry.id)

        # Step 4: LLM analysis
        llm_response = await llm.analyze(sanitized, kb_context)

        confidence = llm_response.get("confidence", 0.0)
        should_escalate = (
            llm_response.get("escalate", False) or
            confidence < ESCALATION_CONFIDENCE_THRESHOLD
        )

        # Step 5: Build response
        if should_escalate:
            response = await self._handle_escalation(
                session, ticket, llm_response, kb_results
            )
        else:
            response = await self._handle_diagnosis(
                session, ticket, llm_response, kb_results
            )

        await session.commit()

        return {
            "ticket_id": ticket.id,
            "status": ticket.status,
            "diagnosis": llm_response.get("diagnosis", ""),
            "confidence": confidence,
            "fixes": llm_response.get("fixes", []),
            "missing_info": llm_response.get("missing_info", []),
            "escalated": ticket.escalated,
            "escalation_reason": ticket.escalation_reason,
            "matched_kb_entries": [
                {"id": e.id, "title": e.title, "category": e.category}
                for e in kb_results
            ],
            "response": response,
        }

    async def _handle_diagnosis(
        self,
        session: AsyncSession,
        ticket: Ticket,
        llm_response: dict,
        kb_results: list,
    ) -> dict:
        """Handle a confident diagnosis with remediation steps."""
        fixes = llm_response.get("fixes", [])
        kb_ids = ",".join(str(e.id) for e in kb_results)

        # Check for auto-remediation
        script_name = None
        script_result = None
        if fixes and AUTO_REMEDIATE:
            for fix in fixes:
                if fix.get("script"):
                    script_name = fix["script"]
                    script_result = self._execute_script(script_name)
                    break

        response = TicketResponse(
            ticket_id=ticket.id,
            response_type="diagnosis",
            content=self._format_diagnosis(llm_response),
            matched_kb_ids=kb_ids,
            confidence=llm_response.get("confidence", 0.0),
            remediation_script=script_name,
            script_executed=script_result is not None,
            script_result=script_result,
        )
        session.add(response)

        ticket.status = "resolved" if script_result else "diagnosed"
        if script_result:
            ticket.resolved_at = datetime.utcnow()

        return {
            "type": "diagnosis",
            "content": response.content,
            "script_executed": response.script_executed,
            "script_result": script_result,
        }

    async def _handle_escalation(
        self,
        session: AsyncSession,
        ticket: Ticket,
        llm_response: dict,
        kb_results: list,
    ) -> dict:
        """Handle low-confidence case by escalating to human technician."""
        reason = llm_response.get("escalation_reason") or "Confidence below threshold"
        missing = llm_response.get("missing_info", [])

        escalation_summary = f"""ESCALATION SUMMARY
===================
Ticket: {ticket.subject}
Confidence: {llm_response.get('confidence', 0.0):.0%}
Reason: {reason}

What the agent tried:
- Searched knowledge base: {len(kb_results)} potential matches found
- LLM analysis: {llm_response.get('diagnosis', 'Inconclusive')}

Missing information needed:
{chr(10).join(f'- {m}' for m in missing) if missing else '- None identified'}

Partial diagnosis (if any):
{llm_response.get('diagnosis', 'Unable to determine root cause')}

Recommended next steps for human technician:
{chr(10).join(f"- {f.get('description', '')}" for f in llm_response.get('fixes', [])) or '- Manual investigation required'}
"""

        response = TicketResponse(
            ticket_id=ticket.id,
            response_type="escalation",
            content=escalation_summary,
            matched_kb_ids=",".join(str(e.id) for e in kb_results),
            confidence=llm_response.get("confidence", 0.0),
        )
        session.add(response)

        ticket.status = "escalated"
        ticket.escalated = True
        ticket.escalation_reason = reason

        return {
            "type": "escalation",
            "content": escalation_summary,
            "missing_info": missing,
        }

    def _build_input(
        self,
        subject: str,
        description: str,
        logs: Optional[str],
        screenshot_text: Optional[str],
    ) -> str:
        """Combine all ticket inputs into a single analysis string."""
        parts = [f"Subject: {subject}", f"Description: {description}"]
        if logs:
            parts.append(f"Logs/Event Viewer Data:\n{logs}")
        if screenshot_text:
            parts.append(f"Text extracted from screenshot:\n{screenshot_text}")
        return "\n\n".join(parts)

    def _format_diagnosis(self, llm_response: dict) -> str:
        """Format LLM response into human-readable diagnosis."""
        lines = [
            f"DIAGNOSIS: {llm_response.get('diagnosis', 'N/A')}",
            f"Confidence: {llm_response.get('confidence', 0):.0%}",
            f"Root Cause: {llm_response.get('root_cause', 'N/A')}",
            "",
            "RECOMMENDED FIXES (ranked by likelihood):",
        ]

        for fix in llm_response.get("fixes", []):
            rank = fix.get("rank", "?")
            lines.append(f"\n#{rank}: {fix.get('description', 'N/A')}")
            lines.append(f"   Why: {fix.get('reason', 'N/A')}")
            if fix.get("script"):
                lines.append(f"   Script: {fix['script']}")
            if fix.get("manual_steps"):
                for step in fix["manual_steps"]:
                    lines.append(f"   - {step}")

        if llm_response.get("missing_info"):
            lines.append("\nADDITIONAL INFORMATION NEEDED:")
            for info in llm_response["missing_info"]:
                lines.append(f"  - {info}")

        return "\n".join(lines)

    def _execute_script(self, script_name: str) -> Optional[str]:
        """Execute a remediation PowerShell script (Windows only)."""
        script_path = SCRIPTS_DIR / script_name
        if not script_path.exists():
            logger.warning(f"Script not found: {script_path}")
            return None

        try:
            result = subprocess.run(
                ["powershell", "-ExecutionPolicy", "Bypass", "-File", str(script_path)],
                capture_output=True,
                text=True,
                timeout=120,
            )
            output = result.stdout + result.stderr
            logger.info(f"Script {script_name} executed. Exit code: {result.returncode}")
            return f"Exit code: {result.returncode}\n{output[:2000]}"
        except subprocess.TimeoutExpired:
            return "Script timed out after 120 seconds"
        except FileNotFoundError:
            return "PowerShell not available (not running on Windows)"
        except Exception as e:
            return f"Script execution failed: {str(e)}"


# Singleton
agent = TroubleshootAgent()
