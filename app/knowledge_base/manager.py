"""
Knowledge base manager: search, match, and manage KB entries.
"""
import re
from typing import Optional
from sqlalchemy import select, func, or_
from sqlalchemy.ext.asyncio import AsyncSession
from loguru import logger
from app.core.models import KnowledgeEntry
from app.knowledge_base.seed_data import KB_ENTRIES


class KBManager:
    """Manages the troubleshooting knowledge base."""

    async def seed(self, session: AsyncSession) -> int:
        """Seed the knowledge base with initial entries if empty."""
        result = await session.execute(select(func.count(KnowledgeEntry.id)))
        count = result.scalar()
        if count > 0:
            logger.info(f"Knowledge base already has {count} entries, skipping seed")
            return count

        for entry_data in KB_ENTRIES:
            entry = KnowledgeEntry(**entry_data)
            session.add(entry)
        await session.commit()
        logger.info(f"Seeded knowledge base with {len(KB_ENTRIES)} entries")
        return len(KB_ENTRIES)

    async def search(
        self,
        session: AsyncSession,
        query: str,
        category: Optional[str] = None,
        limit: int = 5,
    ) -> list[KnowledgeEntry]:
        """Search KB by matching error patterns, codes, and text against the query."""
        results = []

        # First: try regex pattern matching against the query
        all_entries_result = await session.execute(select(KnowledgeEntry))
        all_entries = all_entries_result.scalars().all()

        scored = []
        query_lower = query.lower()

        for entry in all_entries:
            score = 0

            # Pattern match (highest priority)
            try:
                if re.search(entry.error_pattern, query, re.IGNORECASE):
                    score += 10
            except re.error:
                pass

            # Error code match
            if entry.error_code and entry.error_code.lower() in query_lower:
                score += 8

            # Category filter
            if category and entry.category.lower() != category.lower():
                continue

            # Title/description keyword matching
            title_words = set(entry.title.lower().split())
            query_words = set(query_lower.split())
            overlap = len(title_words & query_words)
            score += overlap * 2

            # Tag matching
            if entry.tags:
                tag_set = set(t.strip().lower() for t in entry.tags.split(","))
                tag_overlap = len(tag_set & query_words)
                score += tag_overlap * 3

            # Symptom matching
            if any(word in entry.symptoms.lower() for word in query_words if len(word) > 3):
                score += 2

            if score > 0:
                scored.append((score, entry))

        # Sort by score descending
        scored.sort(key=lambda x: x[0], reverse=True)
        results = [entry for _, entry in scored[:limit]]

        return results

    async def get_by_id(self, session: AsyncSession, entry_id: int) -> Optional[KnowledgeEntry]:
        result = await session.execute(
            select(KnowledgeEntry).where(KnowledgeEntry.id == entry_id)
        )
        return result.scalar_one_or_none()

    async def increment_matched(self, session: AsyncSession, entry_id: int):
        entry = await self.get_by_id(session, entry_id)
        if entry:
            entry.times_matched += 1
            await session.commit()

    async def increment_resolved(self, session: AsyncSession, entry_id: int):
        entry = await self.get_by_id(session, entry_id)
        if entry:
            entry.times_resolved += 1
            await session.commit()

    async def get_stats(self, session: AsyncSession) -> dict:
        """Get knowledge base statistics."""
        total = await session.execute(select(func.count(KnowledgeEntry.id)))
        by_category = await session.execute(
            select(KnowledgeEntry.category, func.count(KnowledgeEntry.id))
            .group_by(KnowledgeEntry.category)
        )
        return {
            "total_entries": total.scalar(),
            "by_category": {row[0]: row[1] for row in by_category.all()},
        }

    def format_for_llm(self, entries: list[KnowledgeEntry]) -> str:
        """Format KB entries as context for the LLM."""
        if not entries:
            return ""

        parts = []
        for i, entry in enumerate(entries, 1):
            parts.append(f"""--- KB Entry #{i} (Confidence: {entry.confidence}) ---
Category: {entry.category} > {entry.subcategory}
Error Code: {entry.error_code or 'N/A'}
Title: {entry.title}
Description: {entry.description}
Symptoms: {entry.symptoms}
Root Cause: {entry.root_cause}
Remediation Steps:
{entry.remediation_steps}
Remediation Script: {entry.remediation_script or 'None (manual steps only)'}
""")
        return "\n".join(parts)


# Singleton
kb_manager = KBManager()
