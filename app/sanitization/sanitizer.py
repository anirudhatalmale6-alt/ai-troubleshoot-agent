"""
Data sanitization module.
Strips sensitive information (PII, credentials, IPs) before sending to LLM.
"""
import re
from typing import Optional
from config.settings import SANITIZE_PATTERNS
from loguru import logger


class DataSanitizer:
    """Sanitizes text data by removing/masking sensitive information."""

    def __init__(self, extra_patterns: Optional[list] = None):
        self.patterns = [re.compile(p) for p in SANITIZE_PATTERNS]
        if extra_patterns:
            self.patterns.extend([re.compile(p) for p in extra_patterns])

        # Replacement labels for each pattern type
        self._replacements = {
            0: "[SSN_REDACTED]",
            1: "[EMAIL_REDACTED]",
            2: "[IP_REDACTED]",
            3: "[CC_REDACTED]",
            4: "password=[REDACTED]",
            5: "api_key=[REDACTED]",
            6: "secret=[REDACTED]",
            7: "token=[REDACTED]",
        }

    def sanitize(self, text: str) -> str:
        """Remove sensitive data from text, returning sanitized version."""
        if not text:
            return text

        sanitized = text
        redaction_count = 0

        for i, pattern in enumerate(self.patterns):
            replacement = self._replacements.get(i, "[REDACTED]")
            new_text = pattern.sub(replacement, sanitized)
            if new_text != sanitized:
                redaction_count += sanitized.count(replacement) == 0
                sanitized = new_text

        if redaction_count > 0:
            logger.info(f"Sanitized {redaction_count} sensitive pattern type(s) from input")

        return sanitized

    def sanitize_dict(self, data: dict) -> dict:
        """Recursively sanitize all string values in a dictionary."""
        sanitized = {}
        for key, value in data.items():
            if isinstance(value, str):
                sanitized[key] = self.sanitize(value)
            elif isinstance(value, dict):
                sanitized[key] = self.sanitize_dict(value)
            elif isinstance(value, list):
                sanitized[key] = [
                    self.sanitize(v) if isinstance(v, str) else v for v in value
                ]
            else:
                sanitized[key] = value
        return sanitized


# Singleton instance
sanitizer = DataSanitizer()
