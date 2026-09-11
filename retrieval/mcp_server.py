#!/usr/bin/env python3
"""Gate 2's MCP tool server. One tool: search_runbooks. Deployed by
kagent's own MCPServer CRD (kagent runs this as a stdio subprocess it
manages, same pattern as its documented mcp-server-fetch example) --
this file is the only custom MCP server this repo needs; everything
else in Gate 1/3 uses kagent's built-in Kubernetes tools.
"""
import os

from mcp.server.fastmcp import FastMCP
from pymilvus import MilvusClient

DB_PATH = os.environ.get("MILVUS_DB_PATH", "./retrieval/runbooks.db")
COLLECTION = "runbooks"

mcp = FastMCP("runbook-search")
_client = MilvusClient(DB_PATH)


@mcp.tool()
def search_runbooks(query: str) -> str:
    """Search incident runbooks for guidance relevant to a Kubernetes
    problem description (e.g. crashloop reason, error message). Returns
    the single best-matching runbook snippet."""
    results = _client.search(
        collection_name=COLLECTION,
        data=[query],
        anns_field="sparse",
        output_fields=["text"],
        limit=1,
    )
    if not results or not results[0]:
        return "No matching runbook found."
    hit = results[0][0]
    return f"[score={hit['distance']:.2f}] {hit['entity']['text']}"


if __name__ == "__main__":
    mcp.run()
