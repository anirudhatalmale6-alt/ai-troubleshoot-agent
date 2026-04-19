"""
Ollama LLM integration for on-premises AI reasoning.
"""
import httpx
import json
from typing import Optional
from loguru import logger
from config.settings import OLLAMA_BASE_URL, OLLAMA_MODEL


SYSTEM_PROMPT = """You are an expert Windows IT troubleshooting agent. Your role is to:
1. Analyze error logs, event viewer data, and user-reported symptoms
2. Identify the root cause of software and hardware issues
3. Provide clear, ranked remediation steps
4. Recommend specific PowerShell remediation scripts when applicable

When analyzing issues:
- Be specific about error codes and their meaning
- Consider both software and hardware causes
- Rank fixes by likelihood of success (most likely first)
- If you cannot determine the issue, list what additional information is needed
- Always explain WHY each step might fix the problem

Format your response as JSON with this structure:
{
    "diagnosis": "Brief summary of the identified issue",
    "confidence": 0.0-1.0,
    "root_cause": "Detailed explanation of the root cause",
    "fixes": [
        {
            "rank": 1,
            "description": "What to do",
            "reason": "Why this might fix it",
            "script": "script_name.ps1 or null",
            "manual_steps": ["Step 1", "Step 2"]
        }
    ],
    "missing_info": ["Any additional info needed"],
    "escalate": false,
    "escalation_reason": null
}"""


class OllamaLLM:
    """Interface to Ollama for local LLM inference."""

    def __init__(self, base_url: str = OLLAMA_BASE_URL, model: str = OLLAMA_MODEL):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.client = httpx.AsyncClient(timeout=120.0)

    async def check_health(self) -> bool:
        """Check if Ollama is running and the model is available."""
        try:
            resp = await self.client.get(f"{self.base_url}/api/tags")
            if resp.status_code == 200:
                models = resp.json().get("models", [])
                model_names = [m.get("name", "") for m in models]
                if self.model in model_names or any(self.model in n for n in model_names):
                    return True
                logger.warning(f"Model '{self.model}' not found. Available: {model_names}")
                return False
            return False
        except Exception as e:
            logger.error(f"Ollama health check failed: {e}")
            return False

    async def analyze(self, ticket_content: str, kb_context: str = "") -> dict:
        """
        Send ticket content to LLM for analysis.

        Args:
            ticket_content: Sanitized ticket description, logs, symptoms
            kb_context: Relevant knowledge base entries for context

        Returns:
            Parsed JSON diagnosis from the LLM
        """
        prompt = f"""Analyze this IT support ticket and provide a diagnosis with remediation steps.

TICKET CONTENT:
{ticket_content}

"""
        if kb_context:
            prompt += f"""RELEVANT KNOWLEDGE BASE ENTRIES (use these as reference):
{kb_context}

"""
        prompt += "Provide your analysis as JSON following the specified format."

        try:
            resp = await self.client.post(
                f"{self.base_url}/api/generate",
                json={
                    "model": self.model,
                    "prompt": prompt,
                    "system": SYSTEM_PROMPT,
                    "stream": False,
                    "options": {
                        "temperature": 0.3,
                        "num_predict": 2048,
                    }
                }
            )

            if resp.status_code != 200:
                logger.error(f"Ollama returned status {resp.status_code}: {resp.text}")
                return self._error_response("LLM service returned an error")

            result = resp.json()
            raw_response = result.get("response", "")
            return self._parse_response(raw_response)

        except httpx.TimeoutException:
            logger.error("Ollama request timed out")
            return self._error_response("Analysis timed out - the issue may be too complex for automated analysis")
        except Exception as e:
            logger.error(f"LLM analysis failed: {e}")
            return self._error_response(f"Analysis failed: {str(e)}")

    def _parse_response(self, raw: str) -> dict:
        """Parse LLM response, extracting JSON from potentially mixed output."""
        # Try direct JSON parse
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            pass

        # Try to find JSON block in the response
        json_start = raw.find("{")
        json_end = raw.rfind("}") + 1
        if json_start != -1 and json_end > json_start:
            try:
                return json.loads(raw[json_start:json_end])
            except json.JSONDecodeError:
                pass

        # Fallback: wrap raw text in a structured response
        logger.warning("Could not parse LLM response as JSON, using raw text")
        return {
            "diagnosis": raw[:500],
            "confidence": 0.5,
            "root_cause": "See diagnosis",
            "fixes": [{"rank": 1, "description": raw, "reason": "LLM analysis", "script": None, "manual_steps": []}],
            "missing_info": [],
            "escalate": False,
            "escalation_reason": None,
        }

    def _error_response(self, message: str) -> dict:
        return {
            "diagnosis": message,
            "confidence": 0.0,
            "root_cause": "Unable to determine",
            "fixes": [],
            "missing_info": [],
            "escalate": True,
            "escalation_reason": message,
        }

    async def close(self):
        await self.client.aclose()


# Singleton
llm = OllamaLLM()
