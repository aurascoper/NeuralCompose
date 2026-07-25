// semanticGraph.ts — bounded graph of everything the dialogue has said and heard.
// Ported from Swift SemanticGraph.swift. Pure value type, no I/O.

import type { Embedding, SemanticNode, SemanticEdge, NodeKind } from './types';
import { normalizedCosine, cosineSimilarity } from './dynamics';

export class SemanticGraph {
  nodes: SemanticNode[] = [];
  edges: SemanticEdge[] = [];
  private capacity: number;
  private edgeThreshold: number;
  private nextID = 0;

  constructor(capacity = 128, edgeThreshold = 0.6) {
    this.capacity = Math.max(1, capacity);
    this.edgeThreshold = edgeThreshold;
  }

  insert(text: string, embedding: Embedding, turnIndex: number, kind: NodeKind): SemanticNode {
    const node: SemanticNode = {
      id: this.nextID,
      text,
      embedding,
      turnIndex,
      kind,
    };
    this.nextID++;
    for (const existing of this.nodes) {
      const w = normalizedCosine(cosineSimilarity(embedding, existing.embedding));
      if (w >= this.edgeThreshold) {
        this.edges.push({ a: existing.id, b: node.id, weight: w });
      }
    }
    this.nodes.push(node);
    this.evictIfNeeded();
    return node;
  }

  private evictIfNeeded(): void {
    while (this.nodes.length > this.capacity) {
      const removed = this.nodes.shift()!;
      this.edges = this.edges.filter(
        (e) => e.a !== removed.id && e.b !== removed.id,
      );
    }
  }

  /** Prior nodes most similar to query, most-similar first, capped at limit. */
  nearestPriorNodes(query: Embedding, limit: number, minSimilarity = 0): SemanticNode[] {
    return this.nodes
      .map((n) => ({
        node: n,
        sim: normalizedCosine(cosineSimilarity(query, n.embedding)),
      }))
      .filter((x) => x.sim >= minSimilarity)
      .sort((a, b) => b.sim - a.sim)
      .slice(0, limit)
      .map((x) => x.node);
  }
}