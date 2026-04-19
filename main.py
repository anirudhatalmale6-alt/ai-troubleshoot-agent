"""
AI Troubleshooting Agent — Main entry point.
"""
import sys
import os
import asyncio

# Ensure project root is in path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from loguru import logger

from config.settings import API_HOST, API_PORT, LOGS_DIR
from app.core.database import init_db, async_session
from app.knowledge_base.manager import kb_manager
from app.api.routes import router

# Configure logging
logger.add(
    LOGS_DIR / "agent_{time}.log",
    rotation="10 MB",
    retention="30 days",
    level="INFO",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown events."""
    # Startup
    logger.info("Starting AI Troubleshooting Agent...")
    await init_db()
    logger.info("Database initialized")

    # Seed knowledge base
    async with async_session() as session:
        count = await kb_manager.seed(session)
        logger.info(f"Knowledge base ready with {count} entries")

    logger.info(f"Agent is running at http://{API_HOST}:{API_PORT}")
    logger.info("API docs available at http://localhost:8000/docs")

    yield

    # Shutdown
    logger.info("Shutting down AI Troubleshooting Agent...")


app = FastAPI(
    title="AI Troubleshooting Agent",
    description="Intelligent IT troubleshooting agent for Windows environments. "
                "Analyzes logs, event viewer data, and symptoms to diagnose and fix issues.",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS (allow internal network access)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register routes
app.include_router(router)


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host=API_HOST,
        port=API_PORT,
        reload=False,
        log_level="info",
    )
