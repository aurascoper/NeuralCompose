// memory.ts — the memory the dialectic lives in.
// Ported from Swift DialecticalMemory.swift.
// Wraps temporal reply/heard rings feeding centroids + the SemanticGraph for recurrence.
// Pure value type; no I/O.

import type { Embedding, DialecticalCandidate, DialecticTuning } from './types';
import { centroid, normalizedCosine, cosineSimilarity, synthesisScore } from './dynamics';
import { SemanticGraph } from './semanticGraph';

export class DialecticalMemory {
  graph: SemanticGraph;
  private heardEmbeddings: Embedding[] = [];
  private replyEmbeddings: Embedding[] = [];
  private historyWindow: number;
  private tensionCeiling: number;
  lowTensionStreak = 0;
  private recentlyVoiced: string[] = [];

  constructor(
    historyWindow = 16,
    graphCapacity = 128,
    edgeThreshold = 0.6,
    tensionCeiling = 0.35,
  ) {
    this.historyWindow = Math.max(1, historyWindow);
    this.tensionCeiling = tensionCeiling;
    this.graph = new SemanticGraph(graphCapacity, edgeThreshold);
  }

  get historyCentroid(): Embedding | null {
    return centroid(this.heardEmbeddings);
  }

  get replyCentroid(): Embedding | null {
    return centroid(this.replyEmbeddings);
  }

  /** Reply spread — wandering dialogue scores high. [0, 1]. */
  get entropy(): number {
    return tension(this.replyEmbeddings);
  }

  /** How fast the machine's semantic position is moving. [0, 1]. */
  get drift(): number {
    if (this.replyEmbeddings.length < 2) return 0;
    let acc = 0;
    for (let i = 1; i < this.replyEmbeddings.length; i++) {
      acc += 1 - normalizedCosine(cosineSimilarity(this.replyEmbeddings[i], this.replyEmbeddings[i - 1]));
    }
    return acc / (this.replyEmbeddings.length - 1);
  }

  recordHeard(text: string, embedding: Embedding, turnIndex: number): void {
    this.heardEmbeddings.push(embedding);
    if (this.heardEmbeddings.length > this.historyWindow) {
      this.heardEmbeddings.shift();
    }
    this.graph.insert(text, embedding, turnIndex, 'heard');
  }

  recordReply(text: string, embedding: Embedding, turnIndex: number): void {
    this.replyEmbeddings.push(embedding);
    if (this.replyEmbeddings.length > this.historyWindow) {
      this.replyEmbeddings.shift();
    }
    this.graph.insert(text, embedding, turnIndex, 'reply');
  }

  /** Updates convergence streak. Call once per turn, AFTER using lowTensionStreak. */
  observe(tension: number): void {
    this.lowTensionStreak = tension <= this.tensionCeiling ? this.lowTensionStreak + 1 : 0;
  }

  /** Records a voiced output so synthesis won't resurface it verbatim. */
  recordVoiced(text: string): void {
    this.recentlyVoiced.push(text);
    if (this.recentlyVoiced.length > this.historyWindow) {
      this.recentlyVoiced.shift();
    }
  }

  /**
   * Looks for a prior reply that bridges the two current poles.
   * Returns it as a synthesis candidate when it clears the bar.
   * null means "no synthesis this turn."
   */
  synthesisCandidate(
    thesis: Embedding,
    antithesis: Embedding,
    tuning: DialecticTuning,
  ): DialecticalCandidate | null {
    const query = centroid([thesis, antithesis]);
    if (!query) return null;

    const bar = this.lowTensionStreak >= tuning.synthesisSustainK
      ? tuning.synthesisLowBar
      : tuning.synthesisHighBar;

    let best: { node: import('./types').SemanticNode; score: number } | null = null;

    for (const node of this.graph.nearestPriorNodes(query, 10)) {
      // Synthesis reconciles from prior REPLIES, not heard input.
      if (node.kind !== 'reply') continue;
      // Don't resurface something just voiced.
      if (this.recentlyVoiced.includes(node.text)) continue;
      const score = synthesisScore(node.embedding, thesis, antithesis);
      if (!best || score > best.score) {
        best = { node, score };
      }
    }

    if (!best || best.score < bar) return null;
    return {
      text: best.node.text,
      embedding: best.node.embedding,
      roleID: 'synthesis',
    };
  }
}

// Re-export for entropy calculation
function tension(embeddings: Embedding[]): number {
  if (embeddings.length < 2) return 0;
  let acc = 0;
  let pairs = 0;
  for (let i = 0; i < embeddings.length; i++) {
    for (let j = i + 1; j < embeddings.length; j++) {
      acc += 1 - normalizedCosine(cosineSimilarity(embeddings[i], embeddings[j]));
      pairs++;
    }
  }
  return pairs === 0 ? 0 : acc / pairs;
}