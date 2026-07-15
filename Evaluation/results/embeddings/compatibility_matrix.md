# Embedding Model Compatibility Matrix

**Generated:** 2026-07-14T12:12:08.061276+00:00
**Candidates:** 17

## Summary

| Classification | Count |
|----------------|-------|
| both | 2 |
| coreml_only | 4 |
| mlx_only | 4 |
| python_only | 7 |
| unsupported | 0 |

## Full Matrix

| Model | Family | Core ML | MLX | Python | Classification | Dim | Size | License |
|-------|--------|---------|-----|--------|----------------|-----|------|---------|
| bge-small-en-v1.5 | BGE | ✓ | ✓ | ✓ | both | 384 | small | mit |
| bge-base-en-v1.5 | BGE | ✓ | ✗ | ✓ | coreml_only | 768 | base | mit |
| bge-m3 | BGE | ✗ | ✗ | ✓ | python_only | 1024 | large | mit |
| multilingual-e5-small | E5 | ✓ | ✗ | ✓ | coreml_only | 384 | small | mit |
| multilingual-e5-base | E5 | ✓ | ✗ | ✓ | coreml_only | 768 | base | mit |
| multilingual-e5-large | E5 | ✗ | ✓ | ✓ | mlx_only | 1024 | large | mit |
| nomic-embed-text-v1.5 | Nomic | ✗ | ✗ | ✓ | python_only | 768 | base | cc-by-nc-4.0 |
| jina-embeddings-v3 | Jina | ✗ | ✗ | ✓ | python_only | 1024 | base | cc-by-nc-4.0 |
| all-MiniLM-L6-v2 | MiniLM | ✓ | ✓ | ✓ | both | 384 | small | apache-2.0 |
| gte-base-en-v1.5 | GTE | ✓ | ✗ | ✓ | coreml_only | 768 | base | apache-2.0 |
| gte-large-en-v1.5 | GTE | ✗ | ✗ | ✓ | python_only | 1024 | large | apache-2.0 |
| Qwen3-Embedding-0.6B | Qwen | ✗ | ✗ | ✓ | python_only | 1024 | base | apache-2.0 |
| stella_en_400M_v5 | Stella | ✗ | ✗ | ✓ | python_only | 1024 | base | mit |
| snowflake-arctic-embed | Arctic | ✗ | ✗ | ✓ | python_only | 1024 | base | apache-2.0 |
| mxbai-embed-large-v1 | MixedBread | ✗ | ✓ | ✓ | mlx_only | 1024 | base | apache-2.0 |
| bge-small-en-v1.5-mlx | BGE | ✗ | ✓ | ✓ | mlx_only | 384 | small | mit |
| all-MiniLM-L6-v2-mlx | MiniLM | ✗ | ✓ | ✓ | mlx_only | 384 | small | apache-2.0 |

## Details

### bge-small-en-v1.5
- **Repo:** BAAI/bge-small-en-v1.5
- **Classification:** both
- **Runtimes:** coreml, mlx, python
- **MLX:** supported — mlx-community/bge-small-en-v1.5-4bit exists

### bge-base-en-v1.5
- **Repo:** BAAI/bge-base-en-v1.5
- **Classification:** coreml_only
- **Runtimes:** coreml, python
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### bge-m3
- **Repo:** BAAI/bge-m3
- **Classification:** python_only
- **Runtimes:** python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### multilingual-e5-small
- **Repo:** intfloat/multilingual-e5-small
- **Classification:** coreml_only
- **Runtimes:** coreml, python
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### multilingual-e5-base
- **Repo:** intfloat/multilingual-e5-base
- **Classification:** coreml_only
- **Runtimes:** coreml, python
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### multilingual-e5-large
- **Repo:** intfloat/multilingual-e5-large
- **Classification:** mlx_only
- **Runtimes:** mlx, python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** supported — mlx-community/multilingual-e5-large exists

### nomic-embed-text-v1.5
- **Repo:** nomic-ai/nomic-embed-text-v1.5
- **Classification:** python_only
- **Runtimes:** python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### jina-embeddings-v3
- **Repo:** jinaai/jina-embeddings-v3
- **Classification:** python_only
- **Runtimes:** python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** not supported — marked mlx_available=false in fixture

### all-MiniLM-L6-v2
- **Repo:** sentence-transformers/all-MiniLM-L6-v2
- **Classification:** both
- **Runtimes:** coreml, mlx, python
- **MLX:** supported — mlx-community/all-MiniLM-L6-v2-4bit exists

### gte-base-en-v1.5
- **Repo:** Alibaba-NLP/gte-base-en-v1.5
- **Classification:** coreml_only
- **Runtimes:** coreml, python
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### gte-large-en-v1.5
- **Repo:** Alibaba-NLP/gte-large-en-v1.5
- **Classification:** python_only
- **Runtimes:** python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### Qwen3-Embedding-0.6B
- **Repo:** Qwen/Qwen3-Embedding-0.6B
- **Classification:** python_only
- **Runtimes:** python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### stella_en_400M_v5
- **Repo:** dunzhang/stella_en_400M_v5
- **Classification:** python_only
- **Runtimes:** python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### snowflake-arctic-embed
- **Repo:** Snowflake/snowflake-arctic-embed-l
- **Classification:** python_only
- **Runtimes:** python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** not supported — no mlx-community conversion found, but architecture is MLX-compatible

### mxbai-embed-large-v1
- **Repo:** mixedbread-ai/mxbai-embed-large-v1
- **Classification:** mlx_only
- **Runtimes:** mlx, python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** supported — mlx-community/mxbai-embed-large-v1 exists

### bge-small-en-v1.5-mlx
- **Repo:** mlx-community/bge-small-en-v1.5-4bit
- **Classification:** mlx_only
- **Runtimes:** mlx, python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** supported — candidate is already mlx-community

### all-MiniLM-L6-v2-mlx
- **Repo:** mlx-community/all-MiniLM-L6-v2-4bit
- **Classification:** mlx_only
- **Runtimes:** mlx, python
- **Core ML:** not supported — marked not coreml_convertible in fixture
- **MLX:** supported — candidate is already mlx-community
