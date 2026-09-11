FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY runbooks.py seed_runbooks.py mcp_server.py ./

ENV MILVUS_DB_PATH=/app/runbooks.db

# Seed the Milvus Lite DB at image build time -- it's just runbook text,
# no reason to redo this at every pod start.
RUN python seed_runbooks.py

CMD ["python", "mcp_server.py"]
