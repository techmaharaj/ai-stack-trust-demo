#!/usr/bin/env python3
"""One-time seed script for Gate 2. Creates the Milvus Lite file-backed
collection and inserts the runbook snippets from runbooks.py, using
Milvus's built-in BM25 full-text search -- no embedding model needed, no
extra RAM/download for one (this cluster is memory-constrained already).
Safe to re-run: drops and recreates the collection each time.
"""
import os

from pymilvus import DataType, Function, FunctionType, MilvusClient

from runbooks import RUNBOOKS

DB_PATH = os.environ.get("MILVUS_DB_PATH", "./retrieval/runbooks.db")
COLLECTION = "runbooks"


def main() -> None:
    client = MilvusClient(DB_PATH)

    if client.has_collection(COLLECTION):
        client.drop_collection(COLLECTION)

    schema = client.create_schema()
    schema.add_field(field_name="id", datatype=DataType.INT64, is_primary=True, auto_id=True)
    schema.add_field(field_name="text", datatype=DataType.VARCHAR, max_length=2000, enable_analyzer=True)
    schema.add_field(field_name="sparse", datatype=DataType.SPARSE_FLOAT_VECTOR)

    schema.add_function(
        Function(
            name="text_bm25",
            input_field_names=["text"],
            output_field_names=["sparse"],
            function_type=FunctionType.BM25,
        )
    )

    index_params = client.prepare_index_params()
    index_params.add_index(
        field_name="sparse",
        index_type="SPARSE_INVERTED_INDEX",
        metric_type="BM25",
        params={"inverted_index_algo": "DAAT_MAXSCORE", "bm25_k1": 1.2, "bm25_b": 0.75},
    )

    client.create_collection(collection_name=COLLECTION, schema=schema, index_params=index_params)
    client.insert(COLLECTION, [{"text": snippet} for snippet in RUNBOOKS])

    print(f"seeded {len(RUNBOOKS)} runbook snippets into {DB_PATH}")


if __name__ == "__main__":
    main()
